#!/usr/bin/env bash
#
# mail2nas - Proxmox VE Helper-Skript: installieren UND aktualisieren
#
# Auf der Proxmox-VE-Host-Shell ausfuehren (Datacenter -> <Node> -> Shell),
# NICHT innerhalb einer Container-Konsole:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/mail2nas.sh)"
#
# Neu installieren: legt eine unprivilegierte LXC an, installiert Docker und
#   mail2nas darin. Es werden KEINE Mail- oder NAS-Zugangsdaten abgefragt -
#   das passiert danach in der Weboberflaeche. Am Ende stehen Adresse und
#   Startpasswort auf dem Bildschirm.
#
# Aktualisieren: findet die LXCs, in denen mail2nas laeuft, und bringt die
#   gewaehlte auf den neuesten Stand - egal, von welcher Version sie kommt
#   (siehe scripts/proxmox/update.sh). Installationen aus der Zeit, als das
#   Share auf dem Proxmox-Host gemountet wurde, koennen dabei auf direktes SMB
#   umgestellt werden; Host-Mount, fstab-Eintrag und Zugangsdatei werden auf
#   Wunsch entfernt.
#
# Ohne Menue:  ... mail2nas.sh install   bzw.   ... mail2nas.sh update [CTID]
#
# Angelehnt an den Stil der "Proxmox VE Helper-Scripts"
# (community-scripts.github.io) - eigenstaendige Implementierung.
#
# Optional per Umgebungsvariable (z. B. fuer eigene Forks):
#   MAIL2NAS_REPO_URL, MAIL2NAS_REPO_BRANCH

set -euo pipefail

REPO_URL="${MAIL2NAS_REPO_URL:-https://github.com/Internerd/mail2nas.git}"
REPO_BRANCH="${MAIL2NAS_REPO_BRANCH:-main}"
RAW_BASE="${MAIL2NAS_RAW_BASE:-https://raw.githubusercontent.com/Internerd/mail2nas/${REPO_BRANCH}}"
APP_DIR="/opt/mail2nas"

# --- Vorbedingungen ----------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root auf dem Proxmox-VE-Host ausfuehren." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1 || ! command -v pveam >/dev/null 2>&1; then
  echo "Dieses Skript muss auf einem Proxmox-VE-Host laufen (pct/pveam nicht gefunden)." >&2
  echo "In einer bestehenden Debian/Ubuntu-LXC/VM stattdessen scripts/proxmox/install.sh verwenden." >&2
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y whiptail
fi

msg() { whiptail --title "mail2nas" --msgbox "$1" 22 78; }
yesno() { whiptail --title "mail2nas" --yesno "$1" 18 78; }
input() { whiptail --title "mail2nas" --inputbox "$1" 10 76 "$2" 3>&1 1>&2 2>&3; }

# Befehl im mail2nas-Container einer LXC ausfuehren.
in_app() {
  local ctid="$1"
  shift
  pct exec "$ctid" -- bash -c "cd $APP_DIR && $*"
}

download() {
  local target
  target="$(mktemp)"
  curl -fsSL "${RAW_BASE}/$1" -o "$target"
  echo "$target"
}

# =============================================================================
# Aktualisieren
# =============================================================================

find_installations() {
  # "<ctid> <name>" fuer jede laufende LXC mit mail2nas darin.
  local id status name
  while read -r id status name; do
    [ "$status" = "running" ] || continue
    if pct exec "$id" -- test -f "$APP_DIR/docker-compose.yml" 2>/dev/null; then
      echo "$id ${name:-ct$id}"
    fi
  done < <(pct list | awk 'NR>1 {print $1, $2, $NF}')
}

convert_host_mount() {
  # Installationen von frueher: das Share ist auf dem Host gemountet und per
  # Bind-Mount durchgereicht. Die Zugangsdaten liegen auf dem Host - damit
  # kann mail2nas selbst per SMB schreiben, und der Mount wird ueberfluessig.
  local ctid="$1"
  local cred="/etc/mail2nas-smb-credentials-${ctid}"
  local host_mount="/mnt/mail2nas-${ctid}"
  [ -f "$cred" ] || return 0

  local unc smb_host smb_share smb_user smb_password smb_domain
  unc="$(awk -v m="$host_mount" '$2 == m && $3 == "cifs" {print $1; exit}' /etc/fstab)"
  if [ -z "$unc" ]; then
    echo "Zugangsdatei $cred gefunden, aber kein fstab-Eintrag fuer $host_mount - uebersprungen."
    return 0
  fi
  smb_host="${unc#//}"; smb_host="${smb_host%%/*}"
  smb_share="${unc#//*/}"
  smb_user="$(sed -n 's/^username=//p' "$cred" | head -1)"
  smb_password="$(sed -n 's/^password=//p' "$cred" | head -1)"
  smb_domain="$(sed -n 's/^domain=//p' "$cred" | head -1)"

  yesno "Diese Installation schreibt noch ueber einen Mount auf dem Proxmox-Host:

  $unc  ->  $host_mount  ->  /mnt/nas in CT $ctid

mail2nas kann die Freigabe inzwischen selbst per SMB ansprechen - dann braucht
es weder den Mount noch die Zugangsdatei auf dem Host.

Jetzt auf direktes SMB umstellen? Vorher wird ein Schreibtest gemacht; schlaegt
er fehl, bleibt alles wie es ist." || return 0

  local payload
  payload="$(SMB_HOST="$smb_host" SMB_SHARE="$smb_share" SMB_USER="$smb_user" \
    SMB_PASSWORD="$smb_password" SMB_DOMAIN="$smb_domain" python3 -c '
import json, os
print(json.dumps({
    "host": os.environ["SMB_HOST"], "share": os.environ["SMB_SHARE"],
    "user": os.environ["SMB_USER"], "password": os.environ["SMB_PASSWORD"],
    "domain": os.environ.get("SMB_DOMAIN", ""), "mount_path": "/mnt/nas",
}))')"

  local rc=0
  printf '%s' "$payload" | pct exec "$ctid" -- bash -c \
    "cd $APP_DIR && docker compose exec -T mail2nas python -m mail2nas.cli archive-to-smb" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "Kein Archiv auf /mnt/nas gefunden - nichts umzustellen."
    return 0
  elif [ "$rc" -ne 0 ]; then
    msg "Die Umstellung hat nicht geklappt (siehe Ausgabe auf der Shell). Es bleibt beim Host-Mount - mail2nas laeuft unveraendert weiter."
    return 0
  fi

  yesno "mail2nas schreibt jetzt direkt per SMB auf $unc.

Soll der alte Host-Mount jetzt entfernt werden?
  - Bind-Mount aus CT $ctid (der Container wird dafuer neu gestartet)
  - Eintrag fuer $host_mount aus /etc/fstab (Sicherung wird angelegt)
  - Zugangsdatei $cred

'Nein' laesst alles stehen; es wird nur nicht mehr benutzt." || return 0

  echo "==> Bind-Mount aus der .env und dem Container entfernen ..."
  in_app "$ctid" "grep -v -e '^NAS_PATH=' -e '^# Das Share ist vom Betriebssystem' -e '^# durchgereicht (docker-compose.local.yml)' -e '^# der Weboberflaeche auf SMB umgestellt' .env > .env.tmp && chmod 600 .env.tmp && mv .env.tmp .env && docker compose up -d --remove-orphans"
  local mp
  mp="$(pct config "$ctid" | awk -v m="$host_mount" -F': ' '/^mp[0-9]+: / { if (index($2, m) == 1) print $1 }' | head -1)"
  if [ -n "$mp" ]; then
    pct set "$ctid" --delete "$mp"
    echo "==> Container $ctid neu starten, damit der Mount-Punkt wegfaellt ..."
    pct reboot "$ctid"
  fi
  echo "==> Host-Mount abbauen ..."
  umount "$host_mount" 2>/dev/null || umount -l "$host_mount" 2>/dev/null || true
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
  awk -v m="$host_mount" '!($2 == m && $3 == "cifs")' /etc/fstab > /etc/fstab.mail2nas.tmp
  cat /etc/fstab.mail2nas.tmp > /etc/fstab
  rm -f /etc/fstab.mail2nas.tmp
  rmdir "$host_mount" 2>/dev/null || true
  shred -u "$cred" 2>/dev/null || rm -f "$cred"
  echo "    Host-Mount entfernt (fstab-Sicherung unter /etc/fstab.bak.*)."
}

do_update() {
  local ctid="${1:-}"
  if [ -z "$ctid" ]; then
    echo "==> Suche LXCs mit mail2nas ..."
    local found=() line
    while read -r line; do
      [ -n "$line" ] && found+=("${line%% *}" "${line#* }")
    done < <(find_installations)
    if [ "${#found[@]}" -eq 0 ]; then
      msg "In keiner laufenden LXC wurde mail2nas gefunden ($APP_DIR).

Gestoppte Container bitte vorher starten. Fuer eine Neuinstallation das Skript erneut aufrufen und 'Neu installieren' waehlen."
      exit 1
    fi
    if [ "${#found[@]}" -eq 2 ]; then
      ctid="${found[0]}"
    else
      ctid="$(whiptail --title "mail2nas" --menu "Welche Installation aktualisieren?" 16 70 6 \
        "${found[@]}" 3>&1 1>&2 2>&3)"
    fi
  fi

  echo "==> Aktualisiere mail2nas in CT $ctid ..."
  local script
  script="$(download scripts/proxmox/update.sh)"
  pct push "$ctid" "$script" /root/mail2nas-update.sh
  rm -f "$script"
  pct exec "$ctid" -- env MAIL2NAS_REPO_URL="$REPO_URL" MAIL2NAS_REPO_BRANCH="$REPO_BRANCH" \
    bash /root/mail2nas-update.sh
  pct exec "$ctid" -- rm -f /root/mail2nas-update.sh

  convert_host_mount "$ctid"

  local ip port
  ip="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(pct exec "$ctid" -- sed -n 's/^WEB_PORT=//p' "$APP_DIR/.env" 2>/dev/null | tr -d "\"'" | tail -1)"
  msg "Update von CT $ctid abgeschlossen.

Weboberflaeche: http://${ip:-<container-ip>}:${port:-8080}/

Alles, was frueher in der .env stand (Postfach, NAS, Einstellungen) und die
mapping.yaml vom Share sind jetzt in der Weboberflaeche - dort bitte kurz
pruefen. Die alte .env liegt als .env.bak.* in $APP_DIR (enthaelt Passwoerter -
nach erfolgreicher Pruefung loeschen).

Naechstes Mal geht es auch in der LXC mit:  mail2nas-update"
}

# =============================================================================
# Neu installieren
# =============================================================================

do_install() {
  msg "mail2nas - neue Installation

Legt eine neue LXC an, installiert Docker und mail2nas darin.

Es werden nur die Container-Ressourcen abgefragt. Postfaecher, NAS-Freigaben,
Zuordnungen und Drucker richtest du danach in der Weboberflaeche ein - die
Adresse und das Startpasswort stehen am Ende hier auf dem Bildschirm."

  local default_ctid ctid ct_hostname cores ram_mb disk_gb bridge unprivileged web_port
  default_ctid="$(pvesh get /cluster/nextid)"
  web_port=8080

  if yesno "Standard-Einstellungen fuer den Container verwenden?

CTID: ${default_ctid} (naechste freie ID)
Hostname: mail2nas
CPU: 1 Kern, RAM: 512 MB, Disk: 4 GB
Netzwerk: vmbr0, DHCP, unprivilegiert
Weboberflaeche auf Port 8080

'Nein' fuehrt durch erweiterte Einstellungen."; then
    ctid="$default_ctid"; ct_hostname="mail2nas"; cores=1; ram_mb=512; disk_gb=4
    bridge="vmbr0"; unprivileged=1
  else
    ctid="$(input 'Container-ID (CTID)' "$default_ctid")"
    ct_hostname="$(input 'Hostname' 'mail2nas')"
    cores="$(input 'CPU-Kerne' '1')"
    ram_mb="$(input 'RAM in MB' '512')"
    disk_gb="$(input 'Disk in GB' '4')"
    bridge="$(input 'Netzwerk-Bridge' 'vmbr0')"
    web_port="$(input 'Port der Weboberflaeche' '8080')"
    if yesno "Unprivilegierten Container erstellen? (empfohlen)"; then
      unprivileged=1
    else
      unprivileged=0
    fi
  fi

  local ct_storage template_storage template tz
  ct_storage="$(pvesm status -content rootdir | awk 'NR>1{print $1; exit}')"
  template_storage="$(pvesm status -content vztmpl | awk 'NR>1{print $1; exit}')"
  [ -n "$ct_storage" ] || { echo "Kein Storage mit rootdir-Unterstuetzung gefunden." >&2; exit 1; }
  [ -n "$template_storage" ] || { echo "Kein Storage fuer Container-Templates gefunden." >&2; exit 1; }

  pveam update >/dev/null 2>&1 || true
  template="$(pveam available | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
  [ -n "$template" ] || { echo "Kein Debian-12-Template in 'pveam available' gefunden." >&2; exit 1; }
  if ! pveam list "$template_storage" 2>/dev/null | grep -q "$template"; then
    echo "Lade Container-Template $template herunter ..."
    pveam download "$template_storage" "$template"
  fi
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Europe/Berlin)"

  echo "==> Erstelle Container $ctid ..."
  pct create "$ctid" "${template_storage}:vztmpl/${template}" \
    --hostname "$ct_hostname" \
    --cores "$cores" \
    --memory "$ram_mb" \
    --swap 0 \
    --rootfs "${ct_storage}:${disk_gb}" \
    --net0 "name=eth0,bridge=${bridge},ip=dhcp" \
    --unprivileged "$unprivileged" \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 1

  echo "==> Warte auf Netzwerk in Container $ctid ..."
  local up=0
  for _ in $(seq 1 30); do
    if pct exec "$ctid" -- getent hosts github.com >/dev/null 2>&1; then up=1; break; fi
    sleep 2
  done
  [ "$up" -eq 1 ] || echo "Warnung: nach 60s noch keine Internetverbindung im Container - fahre fort." >&2

  local env_file install_script
  env_file="$(mktemp)"
  cat > "$env_file" <<ENVEOF
MAIL2NAS_REPO_URL='${REPO_URL}'
MAIL2NAS_REPO_BRANCH='${REPO_BRANCH}'
WEB_PORT='${web_port}'
TZ='${tz}'
ENVEOF
  install_script="$(download scripts/proxmox/install.sh)"
  pct push "$ctid" "$env_file" /root/mail2nas-install.env
  pct push "$ctid" "$install_script" /root/mail2nas-install.sh
  rm -f "$env_file" "$install_script"

  echo "==> Installiere mail2nas im Container $ctid ..."
  pct exec "$ctid" -- bash /root/mail2nas-install.sh
  pct exec "$ctid" -- rm -f /root/mail2nas-install.sh

  local ip password
  ip="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
  password="$(in_app "$ctid" "docker compose exec -T mail2nas python -m mail2nas.cli password" 2>/dev/null || true)"

  local final="Fertig! Container $ctid ($ct_hostname) laeuft.

  Weboberflaeche:  http://${ip:-<container-ip>}:${web_port}/
  Startpasswort:   ${password:-<noch nicht bereit - spaeter: pct exec $ctid -- bash -c 'cd $APP_DIR && docker compose exec mail2nas python -m mail2nas.cli password'>}

Dort der Reihe nach:
  1. Unter 'Passwort' ein eigenes setzen.
  2. Archiv einrichten - die NAS-Freigabe per SMB, mit Verbindungstest.
     Gemountet werden muss nichts, weder hier noch im Container.
  3. Postfach anlegen, mit Anmeldetest.
  4. Zuordnungen anlegen (oder eine alte mapping.yaml importieren).

Update spaeter: dieses Skript erneut starten und 'Aktualisieren' waehlen,
oder in der LXC:  mail2nas-update"
  msg "$final"
  echo "$final"
}

# =============================================================================

MODE="${1:-}"
case "$MODE" in
  install) do_install ;;
  update) do_update "${2:-}" ;;
  "")
    choice="$(whiptail --title "mail2nas" --menu "Was moechtest du tun?" 14 72 2 \
      install "Neu installieren (neue LXC anlegen)" \
      update "Bestehende Installation aktualisieren" 3>&1 1>&2 2>&3)"
    if [ "$choice" = "update" ]; then do_update; else do_install; fi
    ;;
  *) echo "Aufruf: $0 [install|update [CTID]]" >&2; exit 1 ;;
esac
