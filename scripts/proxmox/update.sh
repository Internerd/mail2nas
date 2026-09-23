#!/usr/bin/env bash
#
# mail2nas - Update auf den aktuellen Stand, egal von welcher Version.
#
# INNERHALB der LXC/VM ausfuehren, in der mail2nas laeuft:
#
#   mail2nas-update
#
# (den Befehl legt die Installation bzw. das erste Update an), oder direkt:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"
#
# Vom Proxmox-Host aus geht es bequemer mit dem Helper-Skript
# (scripts/proxmox/mail2nas.sh -> "Bestehende Installation aktualisieren").
#
# Was passiert:
#   1. Sicherung: .env -> .env.bak.<Zeitstempel>, Datenbank -> /data/state.db.bak-<Zeitstempel>
#      (im Docker-Volume, per SQLite-Backup-API - konsistent auch im Betrieb).
#   2. Code holen. Ein Ordner ohne git (Offline-Installation per bootstrap.sh
#      oder scp) wird dabei in einen git-Checkout umgewandelt. Ohne Zugriff auf
#      GitHub: neue Dateien per bootstrap.sh einspielen und dieses Skript mit
#      MAIL2NAS_OFFLINE=1 starten - dann wird nur neu gebaut und migriert.
#   3. Neu bauen (--pull) und starten. Beim ersten Start der neuen Version
#      uebernimmt mail2nas alles, was bisher in der .env stand (Postfach, Archiv,
#      Drucker, Einstellungen) sowie die mapping.yaml vom Share in seine
#      Datenbank - die Datei auf dem Share heisst danach mapping.yaml.migriert.
#   4. Sobald das bestaetigt ist, wird die .env auf die Infrastruktur
#      reduziert (Port, Zeitzone, Log-Level). Zugangsdaten stehen dann nur noch
#      in der Datenbank - und in der Sicherung aus Schritt 1.
#
# Alle bisherigen Generationen werden erkannt:
#   - Docker-cifs-Volume (erste Versionen): SMB-Zugangsdaten in der .env ->
#     mail2nas spricht jetzt direkt SMB, das alte Volume wird entfernt.
#   - Share auf dem Proxmox-Host gemountet (Bind-Mount nach /mnt/nas): bleibt
#     so, bis es im Helper-Skript auf direktes SMB umgestellt wird.
#   - Direktes SMB (STORAGE_BACKEND=smb): nichts zu mounten.
#
# Optional per Umgebungsvariable:
#   MAIL2NAS_TARGET_DIR   (Default: /opt/mail2nas)
#   MAIL2NAS_REPO_URL     (Default: https://github.com/Internerd/mail2nas.git)
#   MAIL2NAS_REPO_BRANCH  (Default: der ausgecheckte Branch, sonst main)
#   MAIL2NAS_OFFLINE=1    (nichts herunterladen, vorhandene Dateien verwenden)
#   MAIL2NAS_KEEP_ENV=1   (die .env nicht aufraeumen)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausfuehren." >&2
  exit 1
fi

TARGET_DIR="${MAIL2NAS_TARGET_DIR:-/opt/mail2nas}"
REPO_URL="${MAIL2NAS_REPO_URL:-https://github.com/Internerd/mail2nas.git}"
WAIT_SECONDS="${MAIL2NAS_WAIT_SECONDS:-180}"
BIN_DIR="${MAIL2NAS_BIN_DIR:-/usr/local/bin}"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { echo "==> $*"; }
warn() { echo "WARNUNG: $*" >&2; }
fail() { echo "FEHLER: $*" >&2; exit 1; }

if [ ! -d "$TARGET_DIR" ]; then
  echo "Verzeichnis $TARGET_DIR existiert nicht - ist mail2nas hier installiert?" >&2
  echo "Fuer eine Erstinstallation: scripts/proxmox/install.sh" >&2
  exit 1
fi
if [ ! -f "$TARGET_DIR/docker-compose.yml" ]; then
  echo "In $TARGET_DIR liegt keine mail2nas-Installation (docker-compose.yml fehlt)." >&2
  echo "Fuer eine Erstinstallation: scripts/proxmox/install.sh" >&2
  exit 1
fi
cd "$TARGET_DIR"

# --- Werkzeuge -----------------------------------------------------------------

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  fail "Weder 'docker compose' noch 'docker-compose' gefunden."
fi

# Wert einer Variable aus der .env, ohne Anfuehrungszeichen.
env_get() {
  [ -f .env ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" .env | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# --- 1. Sicherung ------------------------------------------------------------------

if [ -f .env ]; then
  say "Sicherung der Konfiguration: .env.bak.$STAMP"
  (umask 077 && cp -a .env ".env.bak.$STAMP")
  chmod 600 ".env.bak.$STAMP"
else
  say "Keine .env vorhanden - es wird eine minimale angelegt."
  umask 077
  printf 'WEB_PORT=8080\nTZ=Europe/Berlin\nLOG_LEVEL=INFO\n' > .env
  chmod 600 .env
fi

if "${DC[@]}" ps -q mail2nas 2>/dev/null | grep -q .; then
  say "Sicherung der Datenbank: /data/state.db.bak-$STAMP (im Docker-Volume)"
  "${DC[@]}" exec -T mail2nas python -c "
import sqlite3, sys
source = sqlite3.connect('/data/state.db')
target = sqlite3.connect('/data/state.db.bak-$STAMP')
source.backup(target)
target.close()
" || warn "Datenbank-Sicherung nicht moeglich - weiter ohne."
fi

# --- 2. Code ----------------------------------------------------------------------

BEFORE="$(git rev-parse --short HEAD 2>/dev/null || echo 'ohne git')"
BRANCH="${MAIL2NAS_REPO_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
[ "$BRANCH" = "HEAD" ] && BRANCH=main

if [ "${MAIL2NAS_OFFLINE:-0}" = "1" ]; then
  say "Offline-Modus: es wird nichts heruntergeladen, die vorhandenen Dateien werden gebaut."
else
  if ! command -v git >/dev/null 2>&1; then
    say "git installieren ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git >/dev/null \
      || fail "git fehlt und liess sich nicht installieren. Alternativ: bootstrap.sh + MAIL2NAS_OFFLINE=1."
  fi
  if [ ! -d .git ]; then
    say "Kein git-Checkout (Installation per bootstrap.sh/scp) - wird umgewandelt."
    git init -q
    git remote add origin "$REPO_URL" 2>/dev/null || git remote set-url origin "$REPO_URL"
  fi
  say "Code aktualisieren (Branch: $BRANCH, aktuell: $BEFORE) ..."
  if ! git fetch --depth 1 origin "$BRANCH"; then
    echo "GitHub ist nicht erreichbar. Ohne Internetzugang: scripts/bootstrap.sh der neuen" >&2
    echo "Version hier ausfuehren und danach 'MAIL2NAS_OFFLINE=1 $0' starten." >&2
    exit 1
  fi
  # reset --hard statt merge: lokale Aenderungen am Code duerfen ein
  # Sicherheitsupdate nicht blockieren. .env und Sicherungen sind ignoriert
  # (.gitignore) und bleiben unangetastet.
  git reset -q --hard FETCH_HEAD
  git branch -q -M "$BRANCH" 2>/dev/null || true
fi
AFTER="$(git rev-parse --short HEAD 2>/dev/null || echo 'ohne git')"
if [ "$BEFORE" = "$AFTER" ]; then
  say "Bereits auf dem aktuellen Stand ($AFTER) - baue trotzdem neu, damit Basis-Image"
  echo "    und Abhaengigkeiten aktuelle Sicherheitsupdates bekommen."
else
  say "Aktualisiert: $BEFORE -> $AFTER"
fi

# --- 3. Welche Compose-Dateien? ---------------------------------------------------
#
# Den Bind-Mount (docker-compose.local.yml) braucht nur, wer das Share vom
# Betriebssystem einbinden laesst. Entscheidend ist, was die .env sagt - und
# fehlt dort der Eintrag, welche Generation das ist:
#   STORAGE_BACKEND=local                -> Mount
#   STORAGE_BACKEND=smb                  -> kein Mount
#   ohne Backend, aber NAS_PATH          -> Mount (aufgeraeumte .env, oder Host-Mount)
#   ohne Backend, IMAP_* aber kein SMB_* -> Mount (Host-Mount-Generation)
#   ohne Backend, mit SMB_*              -> kein Mount (Docker-cifs-Generation -> jetzt SMB direkt)
BACKEND="$(env_get STORAGE_BACKEND | tr '[:upper:]' '[:lower:]')"
NAS_PATH_VALUE="$(env_get NAS_PATH)"
NEED_MOUNT=0
case "$BACKEND" in
  local) NEED_MOUNT=1 ;;
  smb) NEED_MOUNT=0 ;;
  *)
    if [ -n "$NAS_PATH_VALUE" ]; then
      NEED_MOUNT=1
    elif [ -n "$(env_get IMAP_HOST)" ] && [ -z "$(env_get SMB_HOST)" ]; then
      NEED_MOUNT=1
    fi
    ;;
esac
COMPOSE_FILES=(-f docker-compose.yml)
if [ "$NEED_MOUNT" -eq 1 ]; then
  COMPOSE_FILES+=(-f docker-compose.local.yml)
  MOUNT_DIR="${NAS_PATH_VALUE:-/mnt/nas}"
  say "Ablage: gemountetes Share unter $MOUNT_DIR (Bind-Mount in den Container)"
  if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    warn "$MOUNT_DIR ist kein Mountpoint - ist das Share eingebunden?"
    warn "mail2nas startet trotzdem, nimmt aber keine Mail an, bis das Archiv in der"
    warn "Weboberflaeche als bereit gemeldet wird."
  fi
else
  say "Ablage: direkt per SMB bzw. wie in der Weboberflaeche eingerichtet (kein Mount)"
fi
dc() { "${DC[@]}" "${COMPOSE_FILES[@]}" "$@"; }

# --- 4. Bauen, starten, Uebernahme abwarten ----------------------------------------

say "Neu bauen (--pull) und starten ..."
dc build --pull
dc up -d --remove-orphans

say "Warte, bis mail2nas laeuft und die alte Konfiguration uebernommen hat ..."
STATUS=""
READY=0
for _ in $(seq 1 $(( WAIT_SECONDS / 2 ))); do
  if STATUS="$(dc exec -T mail2nas python -m mail2nas.cli status 2>/dev/null)" \
     && grep -q '"options_seeded": true' <<<"$STATUS"; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  warn "mail2nas hat sich nach ${WAIT_SECONDS}s nicht gemeldet - die .env bleibt unveraendert."
  warn "Logs: cd $TARGET_DIR && ${DC[*]} logs --tail 100"
fi

# --- 5. .env aufraeumen ---------------------------------------------------------------
#
# Alles, was frueher in der .env konfiguriert wurde, steht jetzt in der
# Datenbank. Die Variablen wuerden ignoriert - aber Passwoerter in einer Datei
# liegen zu lassen, die niemand mehr braucht, ist unnoetig.
LEGACY_KEYS="IMAP_HOST IMAP_PORT IMAP_SSL IMAP_USER IMAP_PASSWORD IMAP_FOLDER
IMAP_PROCESSED_FOLDER IMAP_OVERSIZED_FOLDER IMAP_MODE POLL_INTERVAL_SECONDS STORAGE_BACKEND
STORAGE_ROOT SMB_HOST SMB_SHARE SMB_USER SMB_PASSWORD SMB_DOMAIN SMB_PORT SMB_ROOT SMB_ENCRYPT
MAPPING_PATH FALLBACK_FOLDER MATCH_BODY FILENAME_PREFIX MAX_ATTACHMENT_SIZE_MB MAX_MESSAGE_SIZE_MB
MAX_ATTACHMENTS_PER_MESSAGE BLOCKED_EXTENSIONS QUARANTINE_FOLDER DRY_RUN PRINTING_ENABLED
PRINT_TIMEOUT_SECONDS PRINTABLE_EXTENSIONS PRINTER_NAME PRINTER_DESTINATION PRINTER_SERVER
PRINTER_OPTIONS PRINTER_COPIES WEB_ENABLED WEB_PASSWORD NAS_PATH MAIL2NAS_REPO_URL MAIL2NAS_REPO_BRANCH"

is_legacy() {
  local key="$1" k
  for k in $LEGACY_KEYS; do [ "$k" = "$key" ] && return 0; done
  return 1
}

HAS_LEGACY=0
while IFS= read -r line; do
  key="${line%%=*}"
  key="${key#"${key%%[![:space:]]*}"}"
  case "$line" in \#*|"") continue ;; esac
  if is_legacy "$key" && [ "$key" != "NAS_PATH" ]; then HAS_LEGACY=1; fi
done < .env

if [ "$READY" -eq 1 ] && [ "$HAS_LEGACY" -eq 1 ] && [ "${MAIL2NAS_KEEP_ENV:-0}" != "1" ]; then
  say "Konfiguration ist in der Datenbank - .env auf die Infrastruktur reduzieren ..."
  NEW_ENV="$(mktemp "$TARGET_DIR/.env.new.XXXXXX")"
  {
    echo "# mail2nas - nur noch Infrastruktur. Postfaecher, Archive, Zuordnungen,"
    echo "# Drucker und alle Einstellungen werden in der Weboberflaeche gepflegt."
    echo "# Die vorherige Fassung liegt unter .env.bak.$STAMP (enthaelt Passwoerter -"
    echo "# nach einem erfolgreichen Update loeschen)."
    while IFS= read -r line; do
      case "$line" in \#*|"") continue ;; esac
      key="${line%%=*}"
      key="${key#"${key%%[![:space:]]*}"}"
      is_legacy "$key" && continue
      echo "$line"
    done < .env
    grep -q '^[[:space:]]*TZ=' .env || echo "TZ=Europe/Berlin"
    if [ "$NEED_MOUNT" -eq 1 ]; then
      echo "# Das Share ist vom Betriebssystem eingebunden und wird in den Container"
      echo "# durchgereicht (docker-compose.local.yml). Entfernen, wenn das Archiv in"
      echo "# der Weboberflaeche auf SMB umgestellt ist."
      echo "NAS_PATH=${NAS_PATH_VALUE:-/mnt/nas}"
    fi
  } > "$NEW_ENV"
  chmod 600 "$NEW_ENV"
  mv "$NEW_ENV" .env
  # Container mit der bereinigten Umgebung neu erzeugen.
  dc up -d --remove-orphans
fi

# --- 6. Aufraeumen ---------------------------------------------------------------------

# Das Docker-cifs-Volume der ersten Versionen: nur eine Mount-Beschreibung
# (mit SMB-Passwort in den Volume-Metadaten), keine Daten.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$TARGET_DIR")}"
if docker volume inspect "${PROJECT}_nas" >/dev/null 2>&1; then
  say "Altes cifs-Volume ${PROJECT}_nas entfernen (enthielt nur die Mount-Zugangsdaten) ..."
  docker volume rm "${PROJECT}_nas" >/dev/null 2>&1 || warn "Konnte ${PROJECT}_nas nicht entfernen."
fi

say "Alte, nicht mehr verwendete Images aufraeumen ..."
docker image prune -f >/dev/null 2>&1 || true

# Kurzer Befehl fuer das naechste Mal.
if [ -d "$BIN_DIR" ] && [ -f "$TARGET_DIR/scripts/proxmox/update.sh" ]; then
  cat > "$BIN_DIR/mail2nas-update" <<EOF
#!/bin/sh
# mail2nas auf den neuesten Stand bringen (angelegt von update.sh/install.sh).
MAIL2NAS_TARGET_DIR="$TARGET_DIR" exec bash "$TARGET_DIR/scripts/proxmox/update.sh" "\$@"
EOF
  chmod 755 "$BIN_DIR/mail2nas-update"
fi

# --- Ergebnis ---------------------------------------------------------------------------

WEB_PORT_VALUE="$(env_get WEB_PORT)"
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "Update abgeschlossen ($BEFORE -> $AFTER)."
echo "Weboberflaeche: http://${CT_IP:-<container-ip>}:${WEB_PORT_VALUE:-8080}/"
if [ "$READY" -eq 1 ]; then
  if grep -q '"initial_password_pending": true' <<<"$STATUS"; then
    PASSWORD="$(dc exec -T mail2nas python -m mail2nas.cli password 2>/dev/null || true)"
    [ -n "$PASSWORD" ] && echo "Startpasswort:  $PASSWORD   (nach der Anmeldung bitte aendern)"
  fi
  if grep -q '"archives": 0' <<<"$STATUS"; then
    echo "Noch kein Archiv eingerichtet - bitte in der Weboberflaeche nachholen."
  fi
fi
echo "Status:  cd $TARGET_DIR && ${DC[*]} ps"
echo "Logs:    cd $TARGET_DIR && ${DC[*]} logs -f"
echo "Naechstes Update: mail2nas-update"
