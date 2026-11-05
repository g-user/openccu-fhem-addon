#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Baut das OpenCCU-Add-on "FHEM":
#   1. eigene Perl-Laufzeit (aus Quellen) mit Prefix /usr/local/addons/fhem/perl
#   2. CPAN-Module (XML::Parser, RPC::XML, Net::SSLeay, IO::Socket::SSL, ...)
#   3. buendelt alle nicht-glibc-Bibliotheken (libssl, libcrypto, libexpat, ...)
#      und setzt RUNPATH relativ ($ORIGIN) -> keine Abhaengigkeit vom CCU-System
#   4. packt FHEM + Perl + Skripte in ein offline installierbares Add-on (.tar.gz)
#
# Laeuft als root in einem Debian-bookworm-Container (siehe build.sh / build.ps1)
# oder nativ auf Debian bookworm / Raspberry Pi OS (Legacy, 64-bit).
# Die Zielarchitektur ist immer die des Build-Systems (arm64 fuer den Pi 3).
# -----------------------------------------------------------------------------
set -euo pipefail

SRC_DIR=${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
source <(sed 's/\r$//' "$SRC_DIR/versions.conf")

PREFIX=/usr/local/addons/fhem/perl   # MUSS dem Installationspfad auf der CCU entsprechen
OUT_DIR=${OUT_DIR:-$SRC_DIR/dist}
CACHE_DIR=${CACHE_DIR:-$SRC_DIR/.cache}
WORK=${WORK_DIR:-/tmp/fhem-addon-build}
JOBS=${JOBS:-$(nproc)}
RUN_TESTS=${RUN_TESTS:-0}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNUNG: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mFEHLER: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "Bitte als root ausfuehren (sudo)."
command -v apt-get >/dev/null || die "Nur Debian-basierte Build-Systeme werden unterstuetzt."

# shellcheck disable=SC1091
. /etc/os-release
if [ "${VERSION_CODENAME:-}" != "bookworm" ]; then
  warn "Build-System ist '${VERSION_CODENAME:-unbekannt}', empfohlen ist Debian bookworm (glibc 2.36)."
  warn "Neuere Systeme erzeugen Binaries, die evtl. eine neuere glibc brauchen als OpenCCU hat."
  [ "${ALLOW_OTHER_DISTRO:-0}" = 1 ] || die "Abbruch. Mit ALLOW_OTHER_DISTRO=1 trotzdem bauen."
fi

ARCH=$(uname -m)
log "Build fuer Architektur $ARCH: Perl $PERL_VERSION, FHEM $FHEM_VERSION, Add-on $ADDON_VERSION"

# --- Build-Abhaengigkeiten ----------------------------------------------------
log "Installiere Build-Abhaengigkeiten"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential binutils ca-certificates curl file patchelf openssl \
  libssl-dev libexpat1-dev libcrypt-dev zlib1g-dev xz-utils >/dev/null

mkdir -p "$CACHE_DIR" "$OUT_DIR"
rm -rf "$WORK"; mkdir -p "$WORK"

fetch() { # url ziel
  if [ -s "$2" ]; then echo "  (Cache) $(basename "$2")"; return 0; fi
  echo "  Lade $1"
  curl -fL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

verify_sha256() { # datei erwartet
  [ -n "$2" ] || return 0
  echo "$2  $1" | sha256sum -c - || die "Pruefsumme stimmt nicht: $1"
}

# --- Perl bauen ---------------------------------------------------------------
if [ -e "$PREFIX" ]; then
  [ -f "$PREFIX/.fhem-addon-build" ] || die "$PREFIX existiert und stammt nicht von diesem Build - bitte pruefen."
  rm -rf "$PREFIX"
fi

PERL_TGZ="perl-$PERL_VERSION.tar.gz"
log "Lade Perl $PERL_VERSION"
fetch "https://www.cpan.org/src/5.0/$PERL_TGZ" "$CACHE_DIR/$PERL_TGZ"
expected=${PERL_SHA256:-}
if [ -z "$expected" ]; then
  expected=$(curl -fsL "https://www.cpan.org/src/5.0/$PERL_TGZ.sha256.txt" | awk '{print $1}') || expected=""
fi
[ -n "$expected" ] || warn "Keine Pruefsumme fuer $PERL_TGZ verfuegbar."
verify_sha256 "$CACHE_DIR/$PERL_TGZ" "$expected"

log "Kompiliere Perl (das dauert unter QEMU-Emulation 30-90 Minuten)"
tar -xzf "$CACHE_DIR/$PERL_TGZ" -C "$WORK"
cd "$WORK/perl-$PERL_VERSION"
unset PERL5LIB PERL_MM_OPT PERL_MB_OPT PERL_LOCAL_LIB_ROOT
sh Configure -des \
  -Dprefix="$PREFIX" \
  -Dman1dir=none -Dman3dir=none -Dsiteman1dir=none -Dsiteman3dir=none \
  -Dinstallusrbinperl=n \
  -Doptimize="-O2" >"$WORK/configure.log" 2>&1 || { tail -50 "$WORK/configure.log"; die "Configure fehlgeschlagen"; }
make -j"$JOBS" >"$WORK/make.log" 2>&1 || { tail -50 "$WORK/make.log"; die "make fehlgeschlagen"; }
if [ "$RUN_TESTS" = 1 ]; then
  TEST_JOBS=$JOBS make test_harness || die "Perl-Tests fehlgeschlagen"
fi
make install >"$WORK/install.log" 2>&1 || { tail -50 "$WORK/install.log"; die "make install fehlgeschlagen"; }
touch "$PREFIX/.fhem-addon-build"
PERL="$PREFIX/bin/perl"
"$PERL" -v | sed -n 2p

# --- CPAN-Module ------------------------------------------------------------
log "Installiere CPAN-Module: $CPAN_MODULES"
fetch "https://cpanmin.us" "$CACHE_DIR/cpanm"
export PERL_MM_USE_DEFAULT=1 PERL_CPANM_HOME="$WORK/cpanm-home"
CPANM_OPTS=(--no-man-pages)
[ "$RUN_TESTS" = 1 ] || CPANM_OPTS+=(--notest)
# shellcheck disable=SC2086
"$PERL" "$CACHE_DIR/cpanm" "${CPANM_OPTS[@]}" $CPAN_MODULES \
  || { tail -80 "$PERL_CPANM_HOME/build.log" 2>/dev/null; die "CPAN-Installation fehlgeschlagen"; }

# --- Bibliotheken buendeln + RUNPATH setzen ---------------------------------
LIBDIR="$PREFIX/lib/so"
mkdir -p "$LIBDIR"
# Diese Bibliotheken gehoeren zur glibc und sind auf OpenCCU immer vorhanden
CORE_LIBS_RE='^(linux-vdso|linux-gate|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libresolv\.so|libanl\.so|libmvec\.so|libBrokenLocale\.so)'

list_elfs() {
  find "$PREFIX" -type f \( -perm -u=x -o -name '*.so' -o -name '*.so.*' \) -print0 |
    while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q '^ELF'; then printf '%s\n' "$f"; fi
    done || true
}

log "Buendele benoetigte Shared Libraries nach $LIBDIR"
while :; do
  rm -f "$WORK/.changed"
  while IFS= read -r elf; do
    if { ldd "$elf" 2>/dev/null || true; } | grep -q 'not found'; then
      ldd "$elf"; die "Fehlende Bibliothek fuer $elf"
    fi
    { ldd "$elf" 2>/dev/null || true; } | awk '$2=="=>" && $3 ~ /^\// {print $1, $3}' |
      while read -r soname path; do
        if echo "$soname" | grep -Eq "$CORE_LIBS_RE"; then continue; fi
        [ -e "$LIBDIR/$soname" ] && continue
        cp -L "$path" "$LIBDIR/$soname"
        echo "  + $soname  ($path)"
        touch "$WORK/.changed"
      done
  done < <(list_elfs)
  [ -e "$WORK/.changed" ] || break
done

log "Strippe Binaries und setze RUNPATH"
while IFS= read -r elf; do
  strip --strip-unneeded "$elf" 2>/dev/null || true
  # statisch gelinkte Dateien haben keine dynamische Sektion -> ueberspringen
  patchelf --print-rpath "$elf" >/dev/null 2>&1 || continue
  case "$elf" in
    "$LIBDIR"/*) rp='$ORIGIN' ;;
    *) rp="\$ORIGIN/$(realpath --relative-to="$(dirname "$elf")" "$LIBDIR")" ;;
  esac
  patchelf --set-rpath "$rp" "$elf" || die "patchelf fehlgeschlagen: $elf"
done < <(list_elfs)

log "Pruefe, dass alle Nicht-glibc-Bibliotheken aus dem Add-on geladen werden"
bad=0
while IFS= read -r elf; do
  while read -r soname path; do
    if echo "$soname" | grep -Eq "$CORE_LIBS_RE"; then continue; fi
    case "$(readlink -f "$path")" in
      "$LIBDIR"/*) ;;
      *) echo "  ! $elf -> $soname aus $path"; bad=1 ;;
    esac
  done < <({ ldd "$elf" 2>/dev/null || true; } | awk '$2=="=>" && $3 ~ /^\// {print $1, $3}')
done < <(list_elfs)
[ "$bad" = 0 ] || die "Nicht alle Bibliotheken sind gebuendelt."

# --- Aufraeumen -------------------------------------------------------------
log "Entferne Dokumentation (pod/man)"
find "$PREFIX" -type f -name '*.pod' ! -name 'perldiag.pod' -delete
find "$PREFIX" -depth -type d -empty -delete
rm -rf "$PREFIX/man"

# --- Rauchtest der Perl-Laufzeit --------------------------------------------
log "Rauchtest der Perl-Module"
SMOKE='
use strict; use warnings;
use XML::Parser; use RPC::XML; use RPC::XML::Client; use RPC::XML::Server;
use Net::SSLeay; use IO::Socket::SSL; use Device::SerialPort; use JSON;
XML::Parser->new(Style => "Tree")->parse("<a><b>1</b></a>");
RPC::XML::request->new("system.listMethods")->as_string =~ /methodCall/ or die "RPC::XML defekt\n";
IO::Socket::SSL::SSL_Context->new(SSL_verify_mode => 0) or die "SSL: $IO::Socket::SSL::SSL_ERROR\n";
printf "Perl %vd | %s | Net::SSLeay %s | IO::Socket::SSL %s | XML::Parser %s | RPC::XML %s | Device::SerialPort %s | JSON %s\n",
  $^V, Net::SSLeay::SSLeay_version(0), $Net::SSLeay::VERSION, $IO::Socket::SSL::VERSION,
  $XML::Parser::VERSION, $RPC::XML::VERSION, $Device::SerialPort::VERSION, $JSON::VERSION;
'
MODULE_REPORT=$(env -i PATH=/usr/bin:/bin "$PERL" -e "$SMOKE") || die "Rauchtest fehlgeschlagen"
echo "  $MODULE_REPORT"

# --- FHEM -------------------------------------------------------------------
STAGE="$WORK/stage"
PAY="$STAGE/fhem-addon"
mkdir -p "$PAY/fhem-dist" "$PAY/etc"

FHEM_TGZ="fhem-$FHEM_VERSION.tar.gz"
log "Lade FHEM $FHEM_VERSION"
fetch "https://fhem.de/$FHEM_TGZ" "$CACHE_DIR/$FHEM_TGZ"
verify_sha256 "$CACHE_DIR/$FHEM_TGZ" "${FHEM_SHA256:-}"
tar -xzf "$CACHE_DIR/$FHEM_TGZ" --strip-components=1 -C "$PAY/fhem-dist"
[ -f "$PAY/fhem-dist/fhem.pl" ] || die "fhem.pl nicht im FHEM-Archiv gefunden"
rm -f "$PAY/fhem-dist/fhem.cfg"   # wird durch die OpenCCU-taugliche Vorlage ersetzt

log "Starttest: FHEM mit der gebauten Perl-Laufzeit"
T="$WORK/fhemtest"
cp -a "$PAY/fhem-dist" "$T"
mkdir -p "$T/log"
cat >"$T/test.cfg" <<'EOF'
attr global logfile -
attr global modpath .
attr global statefile ./log/fhem.save
attr global nofork 1
attr global motd none
define WEB FHEMWEB 18083
EOF
( cd "$T" && exec env -i PATH=/usr/bin:/bin "$PERL" fhem.pl test.cfg ) >"$WORK/fhemtest.log" 2>&1 &
FPID=$!
ok=0
for _ in $(seq 1 180); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18083/fhem || true)
  if [ "$code" = 200 ]; then ok=1; break; fi
  kill -0 "$FPID" 2>/dev/null || break
  sleep 1
done
kill "$FPID" 2>/dev/null || true; wait "$FPID" 2>/dev/null || true
if [ "$ok" != 1 ]; then tail -40 "$WORK/fhemtest.log"; die "FHEM startet nicht"; fi
echo "  FHEMWEB antwortet mit HTTP 200"

# --- Add-on zusammenstellen -------------------------------------------------
log "Stelle Add-on zusammen"
cp -a "$PREFIX" "$PAY/perl"
rm -f "$PAY/perl/.fhem-addon-build"
cp -a "$SRC_DIR/addon/bin" "$SRC_DIR/addon/rc.d" "$SRC_DIR/addon/www" "$PAY/"
cp "$SRC_DIR/addon/etc/fhem.cfg.default" "$PAY/etc/"
cp /etc/ssl/certs/ca-certificates.crt "$PAY/etc/cacert.pem"
cp "$SRC_DIR/addon/update_script" "$STAGE/update_script"
echo "$ADDON_VERSION" >"$PAY/VERSION"
echo "$ARCH" >"$PAY/ARCH"

GLIBC_REQ=$(find "$PAY/perl" -type f \( -perm -u=x -o -name '*.so*' \) -exec objdump -T {} + 2>/dev/null |
  grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1) || true
cat >"$PAY/BUILDINFO" <<EOF
Add-on:      $ADDON_VERSION
FHEM:        $FHEM_VERSION
Architektur: $ARCH
Gebaut:      $(date -u '+%Y-%m-%d %H:%M UTC') auf $PRETTY_NAME
Benoetigt:   $GLIBC_REQ (oder neuer)
Module:      $MODULE_REPORT
Gebuendelte Bibliotheken: $(ls "$LIBDIR" | tr '\n' ' ')
EOF

# Windows-Zeilenenden entfernen + Rechte setzen
find "$STAGE/update_script" "$PAY/bin" "$PAY/rc.d" "$PAY/www" "$PAY/etc/fhem.cfg.default" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$STAGE/update_script" "$PAY"/bin/* "$PAY"/rc.d/*

NAME="fhem-openccu-addon-${ADDON_VERSION}-fhem${FHEM_VERSION}-${ARCH}.tar.gz"
log "Packe $NAME"
tar --owner=0 --group=0 -C "$STAGE" -czf "$OUT_DIR/$NAME" update_script fhem-addon
( cd "$OUT_DIR" && sha256sum "$NAME" >"$NAME.sha256" )
[ -n "${HOST_UID:-}" ] && chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT_DIR/$NAME" "$OUT_DIR/$NAME.sha256" || true

cat "$PAY/BUILDINFO"
log "Fertig: $OUT_DIR/$NAME ($(du -h "$OUT_DIR/$NAME" | cut -f1))"
