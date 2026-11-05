# Baut das FHEM-Add-on fuer OpenCCU unter Windows (Docker Desktop erforderlich).
#   .\build.ps1                 arm64 (Raspberry Pi 3/4/5)
#   .\build.ps1 -Arch amd64     x86_64 (OpenCCU als VM)
# Ergebnis: dist\fhem-openccu-addon-<version>-fhem<version>-<arch>.tar.gz
param(
  [ValidateSet("arm64", "amd64")]
  [string]$Arch = "arm64",
  [switch]$RunTests
)
$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker nicht gefunden. Bitte Docker Desktop installieren (https://www.docker.com/products/docker-desktop/)."
}

$root = $PSScriptRoot
$tests = if ($RunTests) { "1" } else { "0" }
# Windows-Zeilenenden im Build-Skript werden im Container entfernt
$cmd = 'sed "s/\r$//" /src/scripts/build-inside.sh > /tmp/build.sh && bash /tmp/build.sh'

docker run --rm --platform "linux/$Arch" `
  -v "${root}:/src" -e SRC_DIR=/src -e RUN_TESTS=$tests `
  debian:bookworm bash -c $cmd
if ($LASTEXITCODE -ne 0) { throw "Build fehlgeschlagen (Exit-Code $LASTEXITCODE)." }

Get-ChildItem (Join-Path $root "dist") -Filter "*.tar.gz" | Format-Table Name, Length, LastWriteTime
