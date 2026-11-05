# FHEM als OpenCCU-Add-on

Dieses Add-on installiert [FHEM](https://fhem.de) auf demselben Raspberry Pi wie OpenCCU.
Es bringt **FHEM und eine eigene Perl-Laufzeit vollständig mit**. Bei der Installation wird
nichts aus dem Internet geladen, das Add-on lässt sich also **offline installieren**.

Enthaltene Perl-Module (zusätzlich zu den Perl-Kernmodulen):

| Modul | Zweck |
|---|---|
| XML::Parser + RPC::XML | XML-RPC, z. B. für HMCCU/HMCCURPCPROC (Anbindung an die CCU) |
| Net::SSLeay + IO::Socket::SSL | HTTPS/TLS (inklusive gebündeltem OpenSSL 3) |
| Device::SerialPort | serielle Geräte (CUL, Zigbee-Sticks usw.) |
| JSON | wird von sehr vielen FHEM-Modulen benötigt (zusätzlich zur Anforderung) |

Die Abhängigkeiten von RPC::XML (unter anderem LWP, HTTP::Daemon) sind ebenfalls enthalten.

## Funktionsweise

* Perl wird aus den Quellen mit dem festen Prefix `/usr/local/addons/fhem/perl` gebaut.
* Alle Bibliotheken außer der glibc (libssl, libcrypto, libexpat, libcrypt …) liegen in
  `perl/lib/so`. Sie werden über einen relativen `RUNPATH` (`$ORIGIN`) gefunden.
  Das Add-on hängt also nur von der glibc des OpenCCU-Systems ab.
* Gebaut wird unter **Debian bookworm (glibc 2.36)**. OpenCCU bringt eine neuere glibc mit,
  daher laufen die Binaries dort.
* Der Build startet FHEM testweise und prüft, ob FHEMWEB antwortet.
* `update_script` testet die Perl-Laufzeit vor der Aktivierung. Schlägt der Test fehl,
  bleibt die vorherige Version aktiv.

## Add-on bauen

OpenCCU auf dem Raspberry Pi 3 ist ein **64-Bit-System (aarch64)**. Das Add-on muss deshalb
für `arm64` gebaut werden. Dafür gibt es drei Wege:

### A) Windows mit Docker Desktop

```powershell
.\build.ps1            # arm64, das ist der Standard
```

Docker Desktop emuliert ARM per QEMU. Der Build dauert damit etwa 30–90 Minuten.

### B) Linux mit Docker

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64   # einmalig: QEMU einrichten
./build.sh
```

### C) Nativ auf einem Raspberry Pi (am schnellsten, ohne Emulation)

Auf einer **zweiten SD-Karte** „Raspberry Pi OS Lite (Legacy, 64-bit)“ installieren.
Das ist die bookworm-Variante. Dann:

```bash
sudo apt-get install -y git
git clone <dieses Repo> && cd openccu-fhem-addon
sudo ./build.sh --native
```

### D) GitHub Actions

Das Repo auf GitHub hochladen und den Workflow **Build FHEM OpenCCU add-on** von Hand
starten. Er baut für arm64 und x86_64. Die Ergebnisse stehen danach unter „Artifacts“.

**Ergebnis:** `dist/fhem-openccu-addon-1.0.0-fhem6.5-aarch64.tar.gz` (plus `.sha256`).
Die Datei `BUILDINFO` im Archiv zeigt die eingebauten Modulversionen und die mindestens
benötigte glibc-Version.

Versionen (Perl, FHEM, Modulliste) stehen in [versions.conf](versions.conf).
Mit `RUN_TESTS=1` laufen zusätzlich die Perl- und CPAN-Testsuites. Das dauert deutlich länger.

## Installation auf OpenCCU

1. WebUI öffnen: **Einstellungen → Systemsteuerung → Zusatzsoftware**.
2. Die `.tar.gz`-Datei auswählen und **Installieren** klicken. Die CCU startet danach neu.
3. FHEM ist anschließend unter `http://<CCU-IP>:8083/fhem` erreichbar.
   In der Zusatzsoftware-Liste öffnet auch der Knopf **Einstellen** die Oberfläche.
4. Ist die Seite nicht erreichbar: **Systemsteuerung → Firewall konfigurieren** öffnen und
   unter „Port-Freigabe“ den Port `8083` eintragen.

Das Installationsprotokoll liegt in `/usr/local/addons/fhem-install.log`.

### Erste Schritte

* **Zugriffsschutz einrichten.** FHEMWEB ist anfangs ohne Passwort erreichbar:
  ```
  define allowed_WEB allowed
  attr allowed_WEB validFor WEB
  attr allowed_WEB basicAuth { "$user:$password" eq "admin:geheim" }
  ```
* **Anbindung an die CCU auf demselben Gerät:**
  ```
  define d_ccu HMCCU 127.0.0.1
  ```
  Alles Weitere steht im [FHEM-Wiki zu HMCCU](https://wiki.fhem.de/wiki/HMCCU).
  Die RPC-Verbindung läuft lokal, dafür muss in der Firewall kein Port geöffnet werden.
* **Serielle Schnittstellen:** `/dev/ttyAMA0`, `/dev/raw-uart` und `/dev/mmd_*` gehören dem
  Funkmodul der CCU. **Diese Schnittstellen nie in FHEM verwenden.** USB-Sticks (CUL, Zigbee …)
  erscheinen als `/dev/ttyUSB*` oder `/dev/ttyACM*`. Die Standard-Konfiguration enthält deshalb
  bewusst kein `usb create`.

### Kommandozeile (SSH)

```sh
/usr/local/etc/config/rc.d/fhem status|start|stop|restart
/usr/local/addons/fhem/bin/fhemcmd "list"           # Befehl an das laufende FHEM senden
. /usr/local/addons/fhem/bin/fhem-env.sh && perl -v  # gebündeltes Perl benutzen
```

## Updates

* **Add-on neu installieren** (eine neuere `.tar.gz`): Ersetzt wird nur die Perl-Laufzeit
  samt Hilfsskripten. Die FHEM-Installation unter `/usr/local/addons/fhem/fhem` mit
  Konfiguration, Logs und eigenen Modulen bleibt unverändert.
* **FHEM selbst** wird wie gewohnt in FHEM mit `update` aktualisiert. Dafür braucht die CCU
  Internetzugang. Für den Betrieb ist er nicht nötig.

## Deinstallation

In der Zusatzsoftware-Liste auf **Deinstallieren** klicken. Vorher werden `fhem.cfg`,
`fhem.save` und `99_*Utils.pm` nach `/usr/local/fhem-backup-<Datum>.tar.gz` gesichert.

## Verzeichnisse auf der CCU

```
/usr/local/addons/fhem/
├── perl/          gebündelte Perl-Laufzeit (perl/lib/so = gebündelte Bibliotheken)
├── fhem/          FHEM (fhem.pl, fhem.cfg, FHEM/, www/, log/)
├── bin/           fhem-env.sh, fhemcmd
├── etc/           cacert.pem (Ersatz, falls OpenCCU keine CA-Liste hat), fhem.cfg.default
└── VERSION, ARCH, BUILDINFO
/usr/local/etc/config/rc.d/fhem            Startskript
/usr/local/etc/config/addons/www/fhem/     Weiterleitung für den Knopf „Einstellen“
```

## Projektaufbau

```
versions.conf              Versionen und Modulliste
build.sh / build.ps1       Build per Docker (oder --native)
scripts/build-inside.sh    eigentlicher Build (Perl, CPAN, Bibliotheken, FHEM, Packen)
addon/update_script        Installation auf der CCU
addon/rc.d/fhem            Start/Stop/Info/Deinstallation
addon/bin, addon/etc, addon/www
.github/workflows/build.yml
```
