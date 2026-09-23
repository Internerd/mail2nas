#!/usr/bin/env bash
#
# mail2nas - Installer, der INNERHALB einer Debian/Ubuntu-LXC oder -VM laeuft
# (normalerweise automatisch von scripts/proxmox/mail2nas.sh aufgerufen).
#
# Kann auch direkt in einer vorhandenen LXC/VM ausgefuehrt werden:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/install.sh)"
#
# Es werden KEINE Zugangsdaten abgefragt: Postfaecher, NAS-Freigaben,
# Zuordnungen und Drucker werden nach der Installation in der Weboberflaeche
# eingerichtet. Das erste Passwort fuer die Oberflaeche erzeugt mail2nas
# selbst; dieses Skript zeigt es am Ende an.
#
# Liegt schon eine Installation vor, wird stattdessen aktualisiert
# (scripts/proxmox/update.sh) - ein erneuter Aufruf ist also gefahrlos.
#
# Optional per Umgebungsvariable (oder in /root/mail2nas-install.env):
#   MAIL2NAS_REPO_URL, MAIL2NAS_REPO_BRANCH, MAIL2NAS_TARGET_DIR
#   WEB_PORT (Default 8080), TZ (Default Europe/Berlin)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausfuehren." >&2
  exit 1
fi

if [ -f /root/mail2nas-install.env ]; then
  set -a
  # shellcheck disable=SC1091
  source /root/mail2nas-install.env
  set +a
  rm -f /root/mail2nas-install.env
fi

REPO_URL="${MAIL2NAS_REPO_URL:-https://github.com/Internerd/mail2nas.git}"
REPO_BRANCH="${MAIL2NAS_REPO_BRANCH:-main}"
TARGET_DIR="${MAIL2NAS_TARGET_DIR:-/opt/mail2nas}"
RAW_BASE="${MAIL2NAS_RAW_BASE:-https://raw.githubusercontent.com/Internerd/mail2nas/${REPO_BRANCH}}"
WEB_PORT="${WEB_PORT:-8080}"
TZ_VALUE="${TZ:-Europe/Berlin}"

# --- Bestehende Installation? Dann ist das ein Update. ------------------------------

if [ -f "$TARGET_DIR/docker-compose.yml" ]; then
  echo "==> In $TARGET_DIR liegt bereits mail2nas - es wird aktualisiert."
  UPDATE_SCRIPT="$(mktemp)"
  # Das aktuelle Update-Skript holen, nicht das der alten Installation: nur das
  # neue kennt alle Generationen und die Migration.
  if ! curl -fsSL "${RAW_BASE}/scripts/proxmox/update.sh" -o "$UPDATE_SCRIPT"; then
    cp "$TARGET_DIR/scripts/proxmox/update.sh" "$UPDATE_SCRIPT"
  fi
  MAIL2NAS_TARGET_DIR="$TARGET_DIR" MAIL2NAS_REPO_URL="$REPO_URL" \
    MAIL2NAS_REPO_BRANCH="$REPO_BRANCH" exec bash "$UPDATE_SCRIPT"
fi

# --- Pakete und Docker -------------------------------------------------------------

echo "==> Pakete installieren (git, curl, ca-certificates) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg git >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker installieren (offizielles get.docker.com-Skript) ..."
  curl -fsSL https://get.docker.com | sh
fi

# --- Code -----------------------------------------------------------------------------

echo "==> mail2nas holen (${REPO_URL} @ ${REPO_BRANCH}) ..."
mkdir -p "$(dirname "$TARGET_DIR")"
git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$TARGET_DIR"
cd "$TARGET_DIR"

# --- .env: nur Infrastruktur ------------------------------------------------------------

echo "==> .env schreiben (nur Port, Zeitzone, Log-Level) ..."
umask 077
cat > .env <<ENVEOF
# mail2nas - nur Infrastruktur. Postfaecher, Archive (NAS-Freigaben),
# Zuordnungen, Drucker und alle Einstellungen werden in der Weboberflaeche
# gepflegt und in der Datenbank im Docker-Volume "state" gespeichert.
WEB_PORT=${WEB_PORT}
TZ=${TZ_VALUE}
LOG_LEVEL=INFO
ENVEOF
chmod 600 .env

# --- Start -------------------------------------------------------------------------------

echo "==> Bauen und starten ..."
docker compose up -d --build

echo "==> Warte auf die Weboberflaeche ..."
PASSWORD=""
for _ in $(seq 1 60); do
  if PASSWORD="$(docker compose exec -T mail2nas python -m mail2nas.cli password 2>/dev/null)" \
     && [ -n "$PASSWORD" ]; then
    break
  fi
  PASSWORD=""
  sleep 2
done

cat > /usr/local/bin/mail2nas-update <<EOF
#!/bin/sh
# mail2nas auf den neuesten Stand bringen (angelegt von install.sh).
MAIL2NAS_TARGET_DIR="$TARGET_DIR" exec bash "$TARGET_DIR/scripts/proxmox/update.sh" "\$@"
EOF
chmod 755 /usr/local/bin/mail2nas-update

CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "mail2nas laeuft."
echo
echo "  Weboberflaeche: http://${CT_IP:-<container-ip>}:${WEB_PORT}/"
if [ -n "$PASSWORD" ]; then
  echo "  Startpasswort:  $PASSWORD"
else
  echo "  Startpasswort:  cd $TARGET_DIR && docker compose exec mail2nas python -m mail2nas.cli password"
fi
echo
echo "Naechste Schritte - alles in der Weboberflaeche:"
echo "  1. Anmelden und unter 'Passwort' ein eigenes setzen."
echo "  2. Archiv einrichten (NAS-Freigabe per SMB - 'Verbindung testen')."
echo "  3. Postfach anlegen ('Anmeldung und Ordner pruefen')."
echo "  4. Zuordnungen anlegen - oder eine alte mapping.yaml importieren."
echo
echo "Logs:    cd $TARGET_DIR && docker compose logs -f"
echo "Update:  mail2nas-update"
