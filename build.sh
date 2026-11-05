#!/usr/bin/env bash
# Baut das FHEM-Add-on fuer OpenCCU.
#
#   ./build.sh                 Docker-Build fuer arm64 (Raspberry Pi 3/4/5 mit OpenCCU)
#   ./build.sh --arch amd64    Docker-Build fuer x86_64 (OpenCCU als VM / generic-x86_64)
#   sudo ./build.sh --native   direkt auf einem Debian-bookworm-/Raspberry-Pi-OS-System bauen
#
# Ergebnis: dist/fhem-openccu-addon-<version>-fhem<version>-<arch>.tar.gz
set -euo pipefail
cd "$(dirname "$0")"

MODE=docker
ARCH=arm64
while [ $# -gt 0 ]; do
  case "$1" in
    --native) MODE=native ;;
    --arch)   ARCH=$2; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
  shift
done

if [ "$MODE" = native ]; then
  exec env SRC_DIR="$PWD" bash scripts/build-inside.sh
fi

command -v docker >/dev/null || { echo "Docker nicht gefunden. Alternativ: sudo ./build.sh --native"; exit 1; }

# Pruefen, ob fremde Architekturen per QEMU emuliert werden koennen
if ! docker run --rm --platform "linux/$ARCH" debian:bookworm-slim true >/dev/null 2>&1; then
  echo "Container fuer linux/$ARCH laeuft nicht. QEMU-Emulation einrichten mit:"
  echo "  docker run --privileged --rm tonistiigi/binfmt --install $ARCH"
  exit 1
fi

docker run --rm --platform "linux/$ARCH" \
  -v "$PWD:/src" -e SRC_DIR=/src \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -e JOBS="${JOBS:-}" -e RUN_TESTS="${RUN_TESTS:-0}" \
  debian:bookworm \
  bash -c 'sed "s/\r$//" /src/scripts/build-inside.sh > /tmp/build.sh && JOBS=${JOBS:-$(nproc)} bash /tmp/build.sh'
