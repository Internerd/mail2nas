#!/usr/bin/env bash
#
# mail2nas - Proxmox VE Helper-Skript
#
# Auf der Proxmox-VE-Host-Shell ausfuehren (Datacenter -> <Node> -> Shell),
# NICHT innerhalb einer Container-Konsole:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/mail2nas.sh)"
#
# Legt eine neue, unprivilegierte LXC an, installiert darin Docker und
# mail2nas und schreibt die .env anhand deiner Eingaben. Angelehnt an den
# Stil der bekannten "Proxmox VE Helper-Scripts" (community-scripts.github.io) -
# eigenstaendige Neuimplementierung fuer dieses Projekt, keine Codeuebernahme.
#
# Optional per Umgebungsvariable ueberschreibbar (z. B. fuer eigene Forks):
#   MAIL2NAS_REPO_URL, MAIL2NAS_REPO_BRANCH

set -euo pipefail

REPO_URL="${MAIL2NAS_REPO_URL:-https://github.com/Internerd/mail2nas.git}"
REPO_BRANCH="${MAIL2NAS_REPO_BRANCH:-main}"
RAW_BASE="${MAIL2NAS_RAW_BASE:-https://raw.githubusercontent.com/Internerd/mail2nas/${REPO_BRANCH}}"

# --- Vorbedingungen ----------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root auf dem Proxmox-VE-Host ausfuehren." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1 || ! command -v pveam >/dev/null 2>&1; then
  echo "Dieses Skript muss auf einem Proxmox-VE-Host laufen (pct/pveam nicht gefunden)." >&2
  echo "Fuer eine bestehende Debian/Ubuntu-LXC/VM stattdessen scripts/proxmox/install.sh verwenden." >&2
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y whiptail
fi

msg() { whiptail --title "mail2nas" --msgbox "$1" 18 76; }
yesno() { whiptail --title "mail2nas" --yesno "$1" 14 76; }
input() { whiptail --title "mail2nas" --inputbox "$1" 10 76 "$2" 3>&1 1>&2 2>&3; }
password() { whiptail --title "mail2nas" --passwordbox "$1" 10 76 3>&1 1>&2 2>&3; }
menu2() { whiptail --title "mail2nas" --menu "$1" 14 76 2 "$2" "$3" "$4" "$5" 3>&1 1>&2 2>&3; }

msg "mail2nas Proxmox-Installer

Legt eine neue LXC an, installiert Docker darin und deployt mail2nas (IMAP -> SMB Anhang-Archivierung mit Stichwort-Mapping).

Du wirst zuerst nach den Container-Ressourcen gefragt, danach nach IMAP- und SMB-Zugangsdaten. Alle Passwoerter landen ausschliesslich in der .env der Ziel-LXC, niemals im Bash-Verlauf des Proxmox-Hosts."

# --- Container-Einstellungen --------------------------------------------------

DEFAULT_CTID="$(pvesh get /cluster/nextid)"

if yesno "Standard-Einstellungen fuer den Container verwenden?

CTID: ${DEFAULT_CTID} (naechste freie ID)
Hostname: mail2nas
CPU: 1 Kern, RAM: 512 MB, Disk: 4 GB
Netzwerk: vmbr0, DHCP, unprivilegiert

'Nein' fuehrt durch erweiterte Einstellungen."; then
  CTID="$DEFAULT_CTID"
  CT_HOSTNAME="mail2nas"
  CORES=1
  RAM_MB=512
  DISK_GB=4
  BRIDGE="vmbr0"
  UNPRIVILEGED=1
else
  CTID="$(input 'Container-ID (CTID)' "$DEFAULT_CTID")"
  CT_HOSTNAME="$(input 'Hostname' 'mail2nas')"
  CORES="$(input 'CPU-Kerne' '1')"
  RAM_MB="$(input 'RAM in MB' '512')"
  DISK_GB="$(input 'Disk in GB' '4')"
  BRIDGE="$(input 'Netzwerk-Bridge' 'vmbr0')"
  if yesno "Unprivilegierten Container erstellen? (empfohlen)"; then
    UNPRIVILEGED=1
  else
    UNPRIVILEGED=0
  fi
fi

# --- Storage & Template ermitteln ---------------------------------------------

CT_STORAGE="$(pvesm status -content rootdir | awk 'NR>1{print $1; exit}')"
TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR>1{print $1; exit}')"

if [ -z "$CT_STORAGE" ]; then
  echo "Kein Storage mit rootdir-Unterstuetzung gefunden (pvesm status -content rootdir)." >&2
  exit 1
fi
if [ -z "$TEMPLATE_STORAGE" ]; then
  echo "Kein Storage mit Container-Template-Unterstuetzung gefunden (pvesm status -content vztmpl)." >&2
  exit 1
fi

pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
if [ -z "$TEMPLATE" ]; then
  echo "Kein Debian-12-Template in 'pveam available' gefunden." >&2
  exit 1
fi
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  echo "Lade Container-Template $TEMPLATE herunter ..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# --- App-Konfiguration: IMAP --------------------------------------------------

IMAP_HOST="$(input 'IMAP-Server (Host)' 'imap.example.com')"
IMAP_PORT="$(input 'IMAP-Port' '993')"
IMAP_USER="$(input 'IMAP-Benutzer (am besten ein dediziertes Konto)' 'archiv@example.com')"
IMAP_PASSWORD="$(password 'IMAP-Passwort (App-Passwort empfohlen)')"
IMAP_FOLDER="$(input 'Zu ueberwachender IMAP-Ordner' 'INBOX')"
IMAP_MODE="$(menu2 'IMAP-Abrufmodus' idle 'IDLE (Push, empfohlen falls Server es unterstuetzt)' poll 'Polling (regelmaessig pruefen)')"
POLL_INTERVAL_SECONDS="$(input 'Poll-/IDLE-Refresh-Intervall in Sekunden' '300')"

# --- App-Konfiguration: SMB ----------------------------------------------------

SMB_HOST="$(input 'SMB-Server (Host/IP des NAS)' 'nas.local')"
SMB_SHARE="$(input 'SMB-Freigabename' 'Belege')"
SMB_USER="$(input 'SMB-Benutzer (mit Schreibrechten auf die Zielordner)' 'mail2nas')"
SMB_PASSWORD="$(password 'SMB-Passwort')"
SMB_DOMAIN="$(input 'SMB-Domain/Workgroup (leer lassen falls keine)' 'WORKGROUP')"

MAPPING_PATH="$(input 'Pfad zur mapping.yaml relativ zur Freigabe' 'mapping.yaml')"
FALLBACK_FOLDER="$(input 'Fallback-Ordner ohne Mapping-Treffer' 'unsorted')"

msg "Alle Eingaben erfasst.

Container $CTID ($CT_HOSTNAME) wird jetzt erstellt und eingerichtet - das kann je nach Verbindung ein paar Minuten dauern. Dieses Fenster schliesst sich, der Fortschritt laeuft danach im Klartext auf der Shell."

# --- Container erstellen --------------------------------------------------------

echo "==> Erstelle Container $CTID ..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM_MB" \
  --swap 0 \
  --rootfs "${CT_STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged "$UNPRIVILEGED" \
  --features "nesting=1,keyctl=1" \
  --onboot 1 \
  --start 1

echo "==> Warte auf Netzwerk in Container $CTID ..."
NETWORK_UP=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; then
    NETWORK_UP=1
    break
  fi
  sleep 2
done
if [ "$NETWORK_UP" -ne 1 ]; then
  echo "Warnung: Container hat nach 60s noch keine funktionierende DNS-Aufloesung/Internetverbindung. Fahre trotzdem fort." >&2
fi

# --- Konfiguration + Installer in den Container schieben -------------------------

ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<ENVEOF
IMAP_HOST=${IMAP_HOST}
IMAP_PORT=${IMAP_PORT}
IMAP_SSL=true
IMAP_USER=${IMAP_USER}
IMAP_PASSWORD=${IMAP_PASSWORD}
IMAP_FOLDER=${IMAP_FOLDER}
IMAP_MODE=${IMAP_MODE}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS}
SMB_HOST=${SMB_HOST}
SMB_SHARE=${SMB_SHARE}
SMB_USER=${SMB_USER}
SMB_PASSWORD=${SMB_PASSWORD}
SMB_DOMAIN=${SMB_DOMAIN}
MAPPING_PATH=${MAPPING_PATH}
FALLBACK_FOLDER=${FALLBACK_FOLDER}
MAIL2NAS_REPO_URL=${REPO_URL}
MAIL2NAS_REPO_BRANCH=${REPO_BRANCH}
ENVEOF

INSTALL_SCRIPT="$(mktemp)"
curl -fsSL "${RAW_BASE}/scripts/proxmox/install.sh" -o "$INSTALL_SCRIPT"

pct push "$CTID" "$ENV_FILE" /root/mail2nas-install.env
pct push "$CTID" "$INSTALL_SCRIPT" /root/mail2nas-install.sh

shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
rm -f "$INSTALL_SCRIPT"

echo "==> Installiere mail2nas im Container $CTID (Docker, git, Deploy) ..."
pct exec "$CTID" -- bash -c "chmod +x /root/mail2nas-install.sh && /root/mail2nas-install.sh"

CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"

FINAL_MSG="Fertig!

Container $CTID ($CT_HOSTNAME) laeuft unter ${CT_IP:-<unbekannt>}.

Naechster Schritt: config/mapping.example.yaml (im Container unter /opt/mail2nas) als mapping.yaml auf die Wurzel deines SMB-Shares (\"$SMB_SHARE\") kopieren und an deine Stichwoerter anpassen.

Logs pruefen:
  pct exec $CTID -- bash -c 'cd /opt/mail2nas && docker compose logs -f'

Testlauf ohne Nebenwirkungen (DRY_RUN):
  pct exec $CTID -- bash -c 'cd /opt/mail2nas && sed -i \"s/^DRY_RUN=.*/DRY_RUN=true/\" .env && docker compose up -d && docker compose logs -f'"

msg "$FINAL_MSG"
echo "$FINAL_MSG"
