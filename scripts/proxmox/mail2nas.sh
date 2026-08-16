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

# Render a value as a single-quoted shell/dotenv literal. Passwords and other
# free-text input must never land unquoted in a file that gets `source`d or
# parsed by docker compose - otherwise characters like ` or $( ) are executed
# instead of being taken literally.
sq() {
  local v=${1-}
  local q="'"
  local esc="'\\''"
  printf "%s%s%s" "$q" "${v//$q/$esc}" "$q"
}

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

# --- SMB-Share auf dem HOST einbinden -------------------------------------
#
# Bewusst nicht im Container: Dockers cifs-Volume-Treiber setzt den
# mount()-Syscall selbst ab, und den verweigert der Kernel innerhalb einer
# unprivilegierten LXC ("invalid argument"). Ausserdem blieben die
# SMB-Zugangsdaten so in den Volume-Metadaten des Docker-Daemons stehen.
# Stattdessen: Host mountet das Share, die LXC bekommt es per Bind-Mount.

HOST_MOUNT="/mnt/mail2nas-${CTID}"
CRED_FILE="/etc/mail2nas-smb-credentials-${CTID}"

# uid/gid, unter der die Dateien im Container erscheinen sollen. Das Image
# laeuft als uid 1000; in einer unprivilegierten LXC ist das auf dem Host
# uid 100000+1000, weil Proxmox den Namespace ab 100000 abbildet.
if [ "$UNPRIVILEGED" -eq 1 ]; then
  MOUNT_UID=101000
else
  MOUNT_UID=1000
fi

echo "==> SMB-Share auf dem Host einbinden ($HOST_MOUNT) ..."
if ! command -v mount.cifs >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y cifs-utils
fi

umask 077
cat > "$CRED_FILE" <<CREDEOF
username=${SMB_USER}
password=${SMB_PASSWORD}
CREDEOF
# Eine leere domain=-Zeile lassen manche Server/Kernel-Versionen scheitern,
# daher nur schreiben, wenn tatsaechlich eine gesetzt ist.
[ -n "$SMB_DOMAIN" ] && echo "domain=${SMB_DOMAIN}" >> "$CRED_FILE"
chmod 600 "$CRED_FILE"

mkdir -p "$HOST_MOUNT"

FSTAB_LINE="//${SMB_HOST}/${SMB_SHARE} ${HOST_MOUNT} cifs credentials=${CRED_FILE},uid=${MOUNT_UID},gid=${MOUNT_UID},file_mode=0660,dir_mode=0770,vers=3.0,_netdev,nofail 0 0"
if ! grep -qF " ${HOST_MOUNT} cifs " /etc/fstab 2>/dev/null; then
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
  echo "$FSTAB_LINE" >> /etc/fstab
  echo "    fstab-Eintrag ergaenzt (Sicherung unter /etc/fstab.bak.*)"
else
  echo "    fstab-Eintrag fuer $HOST_MOUNT existiert bereits - unveraendert"
fi

mountpoint -q "$HOST_MOUNT" || mount "$HOST_MOUNT"

if ! mountpoint -q "$HOST_MOUNT"; then
  echo >&2
  echo "FEHLER: //${SMB_HOST}/${SMB_SHARE} konnte nicht auf $HOST_MOUNT gemountet werden." >&2
  echo "Haeufige Ursachen: falsche Zugangsdaten, Share-Name mit anderer Gross-/" >&2
  echo "Kleinschreibung, oder der Server verlangt eine andere SMB-Version." >&2
  echo "Manuell testen (andere Version probieren):" >&2
  echo "  mount -t cifs //${SMB_HOST}/${SMB_SHARE} $HOST_MOUNT -o credentials=$CRED_FILE,vers=2.1" >&2
  echo "Danach ggf. vers= in /etc/fstab anpassen und dieses Skript erneut starten." >&2
  exit 1
fi
echo "    Mount erfolgreich."

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
  --mp0 "${HOST_MOUNT},mp=/mnt/nas" \
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
IMAP_HOST=$(sq "$IMAP_HOST")
IMAP_PORT=$(sq "$IMAP_PORT")
IMAP_SSL='true'
IMAP_USER=$(sq "$IMAP_USER")
IMAP_PASSWORD=$(sq "$IMAP_PASSWORD")
IMAP_FOLDER=$(sq "$IMAP_FOLDER")
IMAP_MODE=$(sq "$IMAP_MODE")
POLL_INTERVAL_SECONDS=$(sq "$POLL_INTERVAL_SECONDS")
NAS_PATH='/mnt/nas'
MAPPING_PATH=$(sq "$MAPPING_PATH")
FALLBACK_FOLDER=$(sq "$FALLBACK_FOLDER")
MAIL2NAS_REPO_URL=$(sq "$REPO_URL")
MAIL2NAS_REPO_BRANCH=$(sq "$REPO_BRANCH")
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

Das Share //${SMB_HOST}/${SMB_SHARE} ist auf dem Host unter $HOST_MOUNT eingebunden (Eintrag in /etc/fstab) und als /mnt/nas in den Container durchgereicht. Die SMB-Zugangsdaten liegen nur auf dem Host in $CRED_FILE (chmod 600), nicht im Container.

Naechster Schritt - Mapping-Datei anlegen, direkt vom Host aus:
  cp /var/lib/lxc/$CTID/rootfs/opt/mail2nas/config/mapping.example.yaml $HOST_MOUNT/mapping.yaml 2>/dev/null || pct exec $CTID -- cp /opt/mail2nas/config/mapping.example.yaml /mnt/nas/mapping.yaml
  nano $HOST_MOUNT/mapping.yaml

Logs pruefen:
  pct exec $CTID -- bash -c 'cd /opt/mail2nas && docker compose logs -f'

Testlauf ohne Nebenwirkungen (DRY_RUN):
  pct exec $CTID -- bash -c 'cd /opt/mail2nas && sed -i \"s/^DRY_RUN=.*/DRY_RUN=true/\" .env && docker compose up -d && docker compose logs -f'"

msg "$FINAL_MSG"
echo "$FINAL_MSG"
