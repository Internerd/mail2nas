#!/usr/bin/env bash
#
# mail2nas - Installer, der INNERHALB einer Debian/Ubuntu-LXC oder -VM laeuft
# (normalerweise automatisch von scripts/proxmox/mail2nas.sh aufgerufen).
#
# Kann auch manuell in einer bereits vorhandenen Container/VM ausgefuehrt
# werden, z. B. wenn du den Container selbst per Proxmox-GUI angelegt hast:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/install.sh)"
#
# Erwartet die App-Konfiguration entweder als bereits gesetzte
# Umgebungsvariablen, oder in /root/mail2nas-install.env (wird automatisch
# geladen und danach geloescht, da sie Klartext-Zugangsdaten enthaelt).
# Erforderlich sind nur IMAP_HOST/IMAP_USER/IMAP_PASSWORD.
#
# SMB-Zugangsdaten werden hier NICHT gebraucht: das Share muss bereits vom
# Betriebssystem unter NAS_PATH (Default /mnt/nas) eingebunden sein - siehe
# README, Abschnitt "Warum der SMB-Mount auf dem Host passiert".
# Existiert bereits eine .env und werden keine Zugangsdaten uebergeben,
# laeuft das Skript im Update-Modus und laesst die Konfiguration unveraendert.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausfuehren." >&2
  exit 1
fi

# Render a value as a double-quoted literal for docker compose's .env parser.
#
# Note this is deliberately NOT shell quoting: compose's dotenv parser does not
# understand the shell's '\'' idiom for an embedded single quote and errors out
# on it. Double quotes with \\ , \" and $$ escapes are what it does understand,
# and that combination round-trips every character (quotes, backticks, $( ),
# spaces, #) literally - so a password can never be executed or interpolated.
dq() {
  local v=${1-}
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//\$/\$\$}
  printf '"%s"' "$v"
}

if [ -f /root/mail2nas-install.env ]; then
  set -a
  # shellcheck disable=SC1091
  source /root/mail2nas-install.env
  set +a
fi

REPO_URL="${MAIL2NAS_REPO_URL:-https://github.com/Internerd/mail2nas.git}"
REPO_BRANCH="${MAIL2NAS_REPO_BRANCH:-main}"
TARGET_DIR="${MAIL2NAS_TARGET_DIR:-/opt/mail2nas}"

# Two modes, decided by what is already there:
#
#   Erstinstallation - keine .env vorhanden (oder Zugangsdaten wurden
#     ausdruecklich uebergeben): Zugangsdaten sind Pflicht, .env wird
#     geschrieben.
#   Update - eine .env existiert bereits und es wurden KEINE Zugangsdaten
#     uebergeben: die bestehende Konfiguration bleibt unangetastet, es wird
#     nur der Code aktualisiert und neu gebaut.
#
# Dadurch ist ein erneuter Aufruf gefahrlos: ein Update kostet keine
# Neukonfiguration und kann die vorhandene .env nicht ueberschreiben.
if [ -z "${IMAP_HOST:-}" ] && [ -f "$TARGET_DIR/.env" ]; then
  WRITE_ENV=0
  echo "==> Update-Modus: bestehende $TARGET_DIR/.env bleibt unveraendert."
else
  WRITE_ENV=1
  : "${IMAP_HOST:?IMAP_HOST ist nicht gesetzt}"
  : "${IMAP_USER:?IMAP_USER ist nicht gesetzt}"
  : "${IMAP_PASSWORD:?IMAP_PASSWORD ist nicht gesetzt}"
fi

# Das SMB-Share muss bereits vom Betriebssystem gemountet sein (per Bind-Mount
# vom Proxmox-Host, oder per fstab in einer VM). Lieber hier abbrechen als
# spaeter Anhaenge in ein leeres Verzeichnis schreiben, das beim naechsten
# Neustart verschwindet.
NAS_PATH="${NAS_PATH:-/mnt/nas}"
if [ ! -d "$NAS_PATH" ]; then
  echo "FEHLER: $NAS_PATH existiert nicht." >&2
  echo "Das SMB-Share muss vor der Installation dort eingebunden sein - siehe README" >&2
  echo "(Abschnitt 'Warum der SMB-Mount auf dem Host passiert')." >&2
  exit 1
fi
if ! mountpoint -q "$NAS_PATH" 2>/dev/null; then
  echo "WARNUNG: $NAS_PATH ist kein Mountpoint - liegt das Share wirklich dort?" >&2
  echo "         Anhaenge wuerden sonst in das lokale Dateisystem geschrieben." >&2
fi

echo "==> Pakete installieren (git, cifs-utils, curl, ca-certificates) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg git cifs-utils >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker installieren (offizielles get.docker.com-Skript) ..."
  curl -fsSL https://get.docker.com | sh
fi

echo "==> mail2nas-Code holen (${REPO_URL} @ ${REPO_BRANCH}) ..."
if [ -d "$TARGET_DIR/.git" ]; then
  # FETCH_HEAD statt origin/<branch>: funktioniert auch bei einem flachen
  # Clone zuverlaessig, unabhaengig vom lokalen Branch-Zustand. .env und
  # andere ignorierte Dateien sind von reset --hard nicht betroffen.
  git -C "$TARGET_DIR" fetch --depth 1 origin "$REPO_BRANCH"
  git -C "$TARGET_DIR" reset --hard FETCH_HEAD
else
  mkdir -p "$TARGET_DIR"
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$TARGET_DIR"
fi

cd "$TARGET_DIR"

if [ "$WRITE_ENV" -eq 0 ]; then
  echo "==> .env uebernommen (unveraendert)."
else
echo "==> .env schreiben ..."
umask 077
cat > .env <<ENVEOF
IMAP_HOST=$(dq "${IMAP_HOST}")
IMAP_PORT=$(dq "${IMAP_PORT:-993}")
IMAP_SSL=$(dq "${IMAP_SSL:-true}")
IMAP_USER=$(dq "${IMAP_USER}")
IMAP_PASSWORD=$(dq "${IMAP_PASSWORD}")
IMAP_FOLDER=$(dq "${IMAP_FOLDER:-INBOX}")
IMAP_PROCESSED_FOLDER=$(dq "${IMAP_PROCESSED_FOLDER:-}")
IMAP_OVERSIZED_FOLDER=$(dq "${IMAP_OVERSIZED_FOLDER:-}")
IMAP_MODE=$(dq "${IMAP_MODE:-idle}")
POLL_INTERVAL_SECONDS=$(dq "${POLL_INTERVAL_SECONDS:-300}")

NAS_PATH=$(dq "${NAS_PATH}")

MAPPING_PATH=$(dq "${MAPPING_PATH:-mapping.yaml}")
FALLBACK_FOLDER=$(dq "${FALLBACK_FOLDER:-unsorted}")
MATCH_BODY=$(dq "${MATCH_BODY:-false}")
FILENAME_PREFIX=$(dq "${FILENAME_PREFIX:-date_sender}")

MAX_ATTACHMENT_SIZE_MB=$(dq "${MAX_ATTACHMENT_SIZE_MB:-25}")
MAX_MESSAGE_SIZE_MB=$(dq "${MAX_MESSAGE_SIZE_MB:-50}")
MAX_ATTACHMENTS_PER_MESSAGE=$(dq "${MAX_ATTACHMENTS_PER_MESSAGE:-20}")
BLOCKED_EXTENSIONS=$(dq "${BLOCKED_EXTENSIONS:-exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk}")
QUARANTINE_FOLDER=$(dq "${QUARANTINE_FOLDER:-quarantaene}")

STATE_DB_PATH="/data/state.db"
LOG_LEVEL=$(dq "${LOG_LEVEL:-INFO}")
DRY_RUN=$(dq "${DRY_RUN:-false}")
ENVEOF
chmod 600 .env
fi

echo "==> docker compose build && up -d ..."
docker compose up -d --build

if [ -f /root/mail2nas-install.env ]; then
  shred -u /root/mail2nas-install.env 2>/dev/null || rm -f /root/mail2nas-install.env
fi

echo
if [ "$WRITE_ENV" -eq 0 ]; then
  echo "mail2nas aktualisiert und neu gestartet - Konfiguration unveraendert."
else
  echo "mail2nas laeuft."
fi
echo "Logs:    cd $TARGET_DIR && docker compose logs -f"
echo "Config:  $TARGET_DIR/.env (chmod 600)"

if [ "$WRITE_ENV" -eq 1 ]; then
  echo
  echo "Naechster Schritt: config/mapping.example.yaml als mapping.yaml nach"
  echo "$NAS_PATH kopieren und an deine Stichwoerter anpassen:"
  echo "  cp $TARGET_DIR/config/mapping.example.yaml $NAS_PATH/mapping.yaml"
fi
