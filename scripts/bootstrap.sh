#!/usr/bin/env bash
#
# mail2nas - Offline-Bootstrap
#
# Baut die komplette Projektstruktur an einem Zielpfad neu auf, ganz ohne
# git oder eine Verbindung zu GitHub. Gedacht fuer Proxmox-Hosts/LXCs ohne
# Zugriff auf git: dieses eine Skript per Copy&Paste in eine SSH-Sitzung
# einfuegen (oder per scp/sftp uebertragen) und ausfuehren:
#
#   bash bootstrap.sh [/opt/mail2nas]
#
# Erzeugt darunter: mail2nas/ (Python-Paket), config/, tests/,
# requirements*.txt, Dockerfile, docker-compose.yml, .env.example,
# .dockerignore. Siehe README.md im Original-Repo fuer die Installation
# im Anschluss.
#
# NICHT VON HAND BEARBEITEN - erzeugt von scripts/regenerate-bootstrap.py.

set -euo pipefail

TARGET="${1:-/opt/mail2nas}"
mkdir -p "$TARGET"/mail2nas "$TARGET"/config "$TARGET"/tests "$TARGET"/scripts/proxmox
cd "$TARGET"

echo "Schreibe Projektdateien nach $TARGET ..."

# --- requirements.txt ---
cat > requirements.txt <<'MAIL2NAS_EOF'
imapclient>=3.0,<4.0
PyYAML>=6.0,<7.0
smbprotocol>=1.15,<2.0
Flask>=3.0,<4.0
waitress>=3.0,<4.0
MAIL2NAS_EOF

# --- requirements-dev.txt ---
cat > requirements-dev.txt <<'MAIL2NAS_EOF'
-r requirements.txt
pytest>=8.0,<9.0
MAIL2NAS_EOF

# --- .env.example ---
cat > .env.example <<'MAIL2NAS_EOF'
# mail2nas - Infrastruktur des Containers. Mehr steht hier nicht mehr.
#
# Postfaecher, Archive (NAS-Freigaben), Zuordnungen, Drucker, Zustelladressen,
# Abholordner und alle Einstellungen werden in der Weboberflaeche gepflegt und
# in der Datenbank im Docker-Volume "state" gespeichert - nicht hier, und nicht
# auf dem NAS. Keine dieser Zeilen ist Pflicht; ohne .env gelten die Defaults.
#
# Aeltere .env-Dateien mit IMAP_*, SMB_*, MAPPING_PATH usw. funktionieren
# weiter: ihre Werte werden beim ersten Start einmalig in die Datenbank
# uebernommen, danach ignoriert. scripts/proxmox/update.sh raeumt sie auf.

# Port der Weboberflaeche (auf dem Host und im Container).
WEB_PORT=8080
# Adresse, auf der sie im Container lauscht - normalerweise so lassen.
WEB_HOST=0.0.0.0
# Auf true setzen, wenn die Oberflaeche hinter einem HTTPS-Reverse-Proxy laeuft:
# das Session-Cookie wird dann nur noch ueber TLS gesendet.
WEB_COOKIE_SECURE=false

# Zeitzone - bestimmt das Datum im Dateinamen und die Zeiten im Log.
TZ=Europe/Berlin
LOG_LEVEL=INFO

# Optional: Startpasswort der Weboberflaeche (mind. 8 Zeichen). Ohne Eintrag
# erzeugt mail2nas beim ersten Start ein zufaelliges und zeigt es an
# (Log, sowie: docker compose exec mail2nas python -m mail2nas.cli password).
# WEB_PASSWORD=

# Nur fuer ein Archiv, das vom Betriebssystem gemountet ist (statt direkt per
# SMB): Pfad auf dem Docker-Host, der als /mnt/nas in den Container kommt.
# Mit gesetztem NAS_PATH verwendet update.sh docker-compose.local.yml.
# NAS_PATH=/mnt/nas

# Nur falls die CUPS-Werkzeuge woanders liegen als im Image.
# LP_BINARY=lp
# LPSTAT_BINARY=lpstat
MAIL2NAS_EOF

# --- .dockerignore ---
cat > .dockerignore <<'MAIL2NAS_EOF'
.git
# .env and the credential-bearing backups update.sh writes next to it must
# never enter the build context.
.env
.env.*
!.env.example
__pycache__
*.pyc
.venv
venv
.pytest_cache
tests
README.md
MAIL2NAS_EOF

# --- Dockerfile ---
cat > Dockerfile <<'MAIL2NAS_EOF'
FROM python:3.12-slim

# cups-client provides `lp`, which is how attachments are printed. It is a
# client only - no printing daemon runs in this container; it talks to the
# CUPS server named per printer (or to the host's, via CUPS_SERVER).
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    cups-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mail2nas ./mail2nas

RUN useradd --create-home --uid 1000 mail2nas \
    && mkdir -p /mnt/nas /data \
    && chown -R mail2nas:mail2nas /mnt/nas /data
USER mail2nas

ENV PYTHONUNBUFFERED=1
# The web UI - where everything is configured.
EXPOSE 8080
ENTRYPOINT ["python", "-m", "mail2nas.main"]
MAIL2NAS_EOF

# --- docker-compose.yml ---
cat > docker-compose.yml <<'MAIL2NAS_EOF'
services:
  mail2nas:
    build: .
    image: mail2nas:latest
    container_name: mail2nas
    restart: unless-stopped
    # Only infrastructure lives here (port, time zone, log level). Mailboxes,
    # archives, rules, printers and every setting are configured in the web UI
    # and stored in the "state" volume below.
    env_file:
      - .env
    environment:
      STATE_DB_PATH: /data/state.db
    ports:
      # The web UI. Host and container port are kept identical so WEB_PORT
      # alone decides where it answers. LAN only - see the README.
      - "${WEB_PORT:-8080}:${WEB_PORT:-8080}"
    volumes:
      # The database: configuration, passwords, processed-message tracking.
      # The archive itself is reached over SMB by the application, so nothing
      # else is mounted. For an archive that is a directory mounted by the OS,
      # add docker-compose.local.yml:
      #   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
      - state:/data
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('WEB_PORT', '8080'), timeout=5)"
      interval: 60s
      timeout: 10s
      start_period: 30s
      retries: 3

volumes:
  # Local state - never on the share: it holds the IMAP and SMB passwords.
  state:
MAIL2NAS_EOF

# --- docker-compose.local.yml ---
cat > docker-compose.local.yml <<'MAIL2NAS_EOF'
# Override for an archive that is a directory mounted by the operating system
# (host fstab, or a Proxmox bind mount into the LXC): passes it into the
# container as /mnt/nas. In the web UI the archive is then of the kind
# "Gemountetes Verzeichnis" with the path /mnt/nas.
#
# Not needed at all for the default - an SMB share that mail2nas talks to
# directly. update.sh picks this file automatically when NAS_PATH is set in
# the .env.
#
#   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
#
# Note this is a plain bind mount of an already-mounted directory, never
# Docker's cifs volume driver: that driver issues the mount() syscall itself,
# which the kernel refuses from inside an unprivileged LXC.
services:
  mail2nas:
    volumes:
      - ${NAS_PATH:-/mnt/nas}:/mnt/nas
MAIL2NAS_EOF

# --- config/mapping.example.yaml ---
cat > config/mapping.example.yaml <<'MAIL2NAS_EOF'
# Beispiel fuer Zuordnungen (Stichwort -> Zielordner) zum IMPORT in mail2nas.
#
# Die Zuordnungen liegen in der Datenbank des Containers, nicht als Datei auf
# dem NAS. Gepflegt werden sie in der Weboberflaeche unter "Zuordnungen".
# Diese Datei ist nur ein Startpunkt: dort unter "Sichern und uebertragen"
# importieren ("behalten, neue anhaengen" oder "ersetzen"). Derselbe Knopf
# "Als mapping.yaml herunterladen" erzeugt eine Datei in genau diesem Format -
# als Sicherung oder zum Uebertragen in eine andere Installation.
#
# keyword  Stichwort; geprueft gegen
#            1. den Dateinamen jedes einzelnen Anhangs (zuerst),
#            2. den Betreff (und, falls in den Einstellungen aktiviert, den
#               Mailtext) als Rueckfall, wenn der Dateiname nichts hergibt.
#          Gross-/Kleinschreibung ist egal; * und ? sind Platzhalter.
# folder   Zielordner relativ zur Wurzel des Archivs.
#
# Die Reihenfolge ist die Prioritaet: die erste passende Regel gewinnt.
# Spezielle Stichwoerter gehoeren deshalb VOR allgemeine
# ("Rechnungskorrektur" vor "RE").
#
# Optional je Regel (IDs stehen in der Weboberflaeche bei Postfaechern,
# Druckern und Archiven; unbekannte IDs werden beim Import auf den Standard
# gesetzt):
#   account  nur fuer dieses Postfach   (weglassen = alle Postfaecher)
#   print    true = zusaetzlich drucken (nach der Ablage)
#   printer  dieser Drucker             (weglassen = Drucker des Postfachs)
#   archive  dieses Archiv              (weglassen = Standard-Archiv)
#
# Ohne Treffer landet ein Anhang im Fallback-Ordner, gesperrte Dateitypen
# immer in der Quarantaene - beides unter "Einstellungen". Gesperrte Anhaenge
# werden nie gedruckt.
#
# Das alte flache Format (eine Zeile "Stichwort: ordner" je Regel) wird beim
# Import ebenfalls gelesen; laengere Stichwoerter kommen dabei zuerst.

version: 2
rules:
  - keyword: Rechnungskorrektur
    folder: korrekturen
  - keyword: "Rechnung*"
    folder: rechnungen
    print: true
  - keyword: Invoice
    folder: rechnungen
  - keyword: RE
    folder: rechnungen
  - keyword: Lieferschein
    folder: lieferscheine
  - keyword: Lieferung
    folder: lieferscheine
  - keyword: LS
    folder: lieferscheine
  - keyword: Auftragsbestaetigung
    folder: auftragsbestaetigungen
  - keyword: AB
    folder: auftragsbestaetigungen
  - keyword: Mahnung
    folder: mahnungen
  - keyword: Gutschrift
    folder: gutschriften
MAIL2NAS_EOF

# --- scripts/proxmox/update.sh ---
cat > scripts/proxmox/update.sh <<'MAIL2NAS_EOF'
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
BACKEND="$(env_get STORAGE_BACKEND | tr 'A-Z' 'a-z')"
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
MAIL2NAS_EOF

# --- mail2nas/config.py ---
cat > mail2nas/config.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import re
from dataclasses import dataclass


# Executable/script types that are quarantined instead of filed normally,
# even if their filename happens to match a mapping keyword. This is a
# defense-in-depth measure against mail attachments being used to smuggle
# malware onto the archive share - it does not make opening the quarantined
# file safe, it just keeps it out of the regular business-document folders.
DEFAULT_BLOCKED_EXTENSIONS = (
    "exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,"
    "jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk"
)

# Formats CUPS prints without help. Office documents are deliberately absent:
# without a converter installed they come out as pages of raw markup, and
# installing one is a decision for whoever runs the container.
DEFAULT_PRINTABLE_EXTENSIONS = "pdf,ps,txt,text,log,csv,png,jpg,jpeg,gif,bmp,tif,tiff"


def _bool(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


def parse_extension_list(raw: str) -> frozenset[str]:
    """Normalise a list of file extensions ('.EXE, com; bat' -> {exe, com, bat}).

    Accepts commas, semicolons and whitespace as separators, because the
    field is typed by hand in the web UI and every one of those gets used.
    """
    return frozenset(
        ext.strip().lower().lstrip(".")
        for ext in re.split(r"[,;\s]+", raw or "")
        if ext.strip()
    )




def _int(name: str, default: str, minimum: int = 1, maximum: int | None = None) -> int:
    """Read an integer setting, failing with a usable message instead of a traceback."""
    raw = os.environ.get(name, default).strip()
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"{name} must be a whole number, got {raw!r}") from None
    if value < minimum or (maximum is not None and value > maximum):
        allowed = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise SystemExit(f"{name} must be {allowed}, got {value}")
    return value








def _lpstat_binary() -> str:
    """Where `lpstat` is, defaulting to `lp`'s directory."""
    explicit = os.environ.get("LPSTAT_BINARY", "").strip()
    if explicit:
        return explicit
    lp = os.environ.get("LP_BINARY", "lp").strip() or "lp"
    return lp[:-2] + "lpstat" if lp.endswith("lp") else "lpstat"


@dataclass(frozen=True)
class Config:
    """What the container itself needs before anything else can run.

    Everything about *what* mail2nas does - mailboxes, archives, rules,
    printers, limits - lives in the local database and is edited in the web
    UI. What is left here is infrastructure: where the database is, which port
    the UI listens on, which binaries to call. None of it is secret and none of
    it is required, so a container starts with an empty `.env` and the rest is
    set up in the browser.

    Older `.env` files still work: their values are read once by `legacy.py`
    and carried into the database on the first start of this version.
    """

    state_db_path: str = "/data/state.db"
    web_host: str = "0.0.0.0"
    web_port: int = 8080
    # Initial password only, and optional: without one, a random password is
    # generated on first start. The stored hash wins as soon as there is one.
    web_password: str = ""
    web_cookie_secure: bool = False
    lp_binary: str = "lp"
    # `lpstat` is only used to list a CUPS server's queues for the printer
    # search; it sits next to `lp`, so it is derived from it unless overridden.
    lpstat_binary: str = "lpstat"

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            state_db_path=os.environ.get("STATE_DB_PATH", "/data/state.db").strip() or "/data/state.db",
            web_host=os.environ.get("WEB_HOST", "0.0.0.0").strip() or "0.0.0.0",
            web_port=_int("WEB_PORT", "8080", minimum=1, maximum=65535),
            web_password=os.environ.get("WEB_PASSWORD", ""),
            web_cookie_secure=_bool("WEB_COOKIE_SECURE", False),
            lp_binary=os.environ.get("LP_BINARY", "lp").strip() or "lp",
            lpstat_binary=_lpstat_binary(),
        )

    @property
    def data_dir(self) -> str:
        """The directory next to the database - for files the UI hands out."""
        return os.path.dirname(os.path.abspath(self.state_db_path))
MAIL2NAS_EOF

# --- mail2nas/options.py ---
cat > mail2nas/options.py <<'MAIL2NAS_EOF'
"""The general settings, stored in the database and edited in the web UI.

Everything that used to be a line in the `.env` - folders, limits, the
quarantine list, printing defaults - is an `Options` value now. It is read as
one immutable snapshot, so a worker thread never sees half of a change, and
it is swapped as a whole when the settings page is saved. No restart needed:
the archiver asks for the current snapshot on every message.

Stored as individual keys in the `settings` table rather than as a blob, so
a value added in a later version simply falls back to its default on an
older database instead of making the whole thing unreadable.
"""
from __future__ import annotations

import logging
from collections.abc import Mapping
from dataclasses import dataclass, field, fields, replace

from .config import DEFAULT_BLOCKED_EXTENSIONS, DEFAULT_PRINTABLE_EXTENSIONS, parse_extension_list
from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

SETTING_OPTIONS_SEEDED = "options_seeded"

FILENAME_PREFIXES = {
    "date_sender": "Datum und Absender",
    "date": "nur Datum",
    "sender": "nur Absender",
    "none": "kein Praefix",
}

# (minimum, maximum) for every whole-number setting. Deliberately generous -
# they exist to stop typos ("0", "30000000"), not to second-guess anyone.
LIMITS = {
    "poll_interval": (10, 86_400),
    "max_attachment_size_mb": (1, 2_048),
    "max_message_size_mb": (1, 4_096),
    "max_attachments_per_message": (1, 1_000),
    "pickup_min_age": (0, 86_400),
    "print_timeout": (5, 3_600),
}

# Keys under which each value is stored. Two predate this module and keep
# their names, so an installation that already edited them keeps its values.
_KEYS = {
    "blocked_extensions": "blocked_extensions",
    "pickup_min_age": "pickup_min_age_seconds",
}


class OptionsError(ValueError):
    """A setting the user tried to save is not usable."""


@dataclass(frozen=True)
class Options:
    """One consistent view of every general setting."""

    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    match_body: bool = False
    filename_prefix: str = "date_sender"
    poll_interval: int = 300
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20
    blocked_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_BLOCKED_EXTENSIONS)
    )
    pickup_min_age: int = 20
    printing_enabled: bool = True
    print_timeout: int = 120
    printable_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_PRINTABLE_EXTENSIONS)
    )
    dry_run: bool = False


def _key(name: str) -> str:
    return _KEYS.get(name, f"opt.{name}")


def _encode(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, frozenset):
        return ",".join(sorted(value))
    return str(value)


def _decode(name: str, raw: str, default):
    if isinstance(default, bool):
        return raw.strip().lower() in ("1", "true", "yes", "on")
    if isinstance(default, frozenset):
        return parse_extension_list(raw)
    if isinstance(default, int):
        value = int(raw.strip())
        low, high = LIMITS.get(name, (None, None))
        if (low is not None and value < low) or (high is not None and value > high):
            raise ValueError(f"{value} outside {low}..{high}")
        return value
    return raw


class OptionsStore:
    """Reads and writes `Options` in the key/value settings table."""

    def __init__(self, settings):
        self._settings = settings

    def load(self) -> Options:
        defaults = Options()
        values = {}
        for spec in fields(Options):
            raw = self._settings.get(_key(spec.name))
            if raw is None:
                continue
            try:
                values[spec.name] = _decode(spec.name, raw, getattr(defaults, spec.name))
            except (TypeError, ValueError) as exc:
                # Only possible after hand-editing the database. The default
                # is the safer reading than refusing to start.
                logger.warning("Stored setting %s=%r is unusable (%s) - using the default",
                               spec.name, raw, exc)
        return replace(defaults, **values)

    def save(self, options: Options) -> None:
        for spec in fields(Options):
            self._settings.set(_key(spec.name), _encode(getattr(options, spec.name)))

    def seeded(self) -> bool:
        return bool(self._settings.get(SETTING_OPTIONS_SEEDED))

    def seed(self, legacy) -> bool:
        """Carry the general settings of an older `.env` over, once.

        Returns True if anything was taken over. Values already stored (the
        quarantine list and pickup delay were editable before) win over the
        `.env`: they are the newer statement.
        """
        if self.seeded():
            return False
        taken = False
        if legacy is not None and legacy.has_options:
            current = self.load()
            stored = {
                spec.name for spec in fields(Options)
                if self._settings.get(_key(spec.name)) is not None
            }
            carried = {
                name: getattr(legacy, name)
                for name in (
                    "fallback_folder", "quarantine_folder", "match_body", "filename_prefix",
                    "poll_interval", "max_attachment_size_mb", "max_message_size_mb",
                    "max_attachments_per_message", "blocked_extensions", "dry_run",
                    "printing_enabled", "print_timeout", "printable_extensions",
                )
                if name not in stored
            }
            try:
                self.save(validate(_as_form(replace(current, **carried)), current))
                taken = True
            except OptionsError as exc:
                logger.error("Settings from the .env are not usable (%s) - keeping defaults", exc)
        self._settings.set(SETTING_OPTIONS_SEEDED, "1")
        return taken


def _as_form(options: Options) -> dict[str, str]:
    """An Options value as the settings form would submit it."""
    form = {}
    for spec in fields(Options):
        value = getattr(options, spec.name)
        if isinstance(value, bool):
            if value:
                form[spec.name] = "1"
        elif isinstance(value, frozenset):
            form[spec.name] = ", ".join(sorted(value))
        else:
            form[spec.name] = str(value)
    return form


def as_form(options: Options) -> dict[str, str]:
    return _as_form(options)


def _folder(form: Mapping[str, str], name: str, label: str) -> str:
    value = (form.get(name) or "").strip().replace("\\", "/")
    if not value:
        raise OptionsError(f"Bitte einen {label} angeben.")
    try:
        return "/".join(safe_relative_parts(value))
    except ValueError as exc:
        raise OptionsError(f"{label}: {exc}") from None


def _whole(form: Mapping[str, str], name: str, label: str) -> int:
    raw = (form.get(name) or "").strip()
    try:
        value = int(raw)
    except ValueError:
        raise OptionsError(f"{label} muss eine ganze Zahl sein.") from None
    low, high = LIMITS[name]
    if not low <= value <= high:
        raise OptionsError(f"{label} muss zwischen {low} und {high} liegen.")
    return value


def validate(form: Mapping[str, str], current: Options | None = None) -> Options:
    """Turn the submitted settings form into Options, or explain what is wrong.

    Checkboxes are absent when unticked, so a missing flag means False. The
    extension lists may be empty on purpose - the UI says what that means.
    """
    current = current or Options()
    prefix = (form.get("filename_prefix") or current.filename_prefix).strip()
    if prefix not in FILENAME_PREFIXES:
        raise OptionsError("Unbekanntes Dateinamen-Praefix.")

    fallback = _folder(form, "fallback_folder", "Ordner fuer Anhaenge ohne Treffer")
    quarantine = _folder(form, "quarantine_folder", "Quarantaene-Ordner")
    if fallback == quarantine:
        raise OptionsError(
            "Fallback- und Quarantaene-Ordner muessen verschieden sein - sonst liegen "
            "gesperrte Dateien zwischen den normalen."
        )

    return Options(
        fallback_folder=fallback,
        quarantine_folder=quarantine,
        match_body=bool(form.get("match_body")),
        filename_prefix=prefix,
        poll_interval=_whole(form, "poll_interval", "Das Abrufintervall"),
        max_attachment_size_mb=_whole(form, "max_attachment_size_mb", "Die Groesse je Anhang"),
        max_message_size_mb=_whole(form, "max_message_size_mb", "Die Groesse je Mail"),
        max_attachments_per_message=_whole(
            form, "max_attachments_per_message", "Die Zahl der Anhaenge je Mail"
        ),
        blocked_extensions=parse_extension_list(form.get("blocked_extensions", "")),
        pickup_min_age=_whole(form, "pickup_min_age", "Die Wartezeit fuer Abholordner"),
        printing_enabled=bool(form.get("printing_enabled")),
        print_timeout=_whole(form, "print_timeout", "Die Zeitgrenze fuer Druckauftraege"),
        printable_extensions=parse_extension_list(form.get("printable_extensions", "")),
        dry_run=bool(form.get("dry_run")),
    )
MAIL2NAS_EOF

# --- mail2nas/legacy.py ---
cat > mail2nas/legacy.py <<'MAIL2NAS_EOF'
"""Reading the configuration of an older installation, once.

Up to this version mail2nas was configured through the `.env`: mailbox, NAS
credentials, folders, limits, even the first printer. All of that now lives in
the local database and is edited in the web UI - but an installation that is
updated must come up exactly as it was, without anyone re-typing a password.

So on the first start of this version the old variables are read one last
time, here, and written into the database (see `migrate.py`). After that they
are ignored, and the update script removes them from the `.env`.

Three generations of `.env` exist in the wild, and they differ in the one
thing that matters most - where attachments go:

1. **Docker cifs volume** (the very first versions): `SMB_HOST`, `SMB_SHARE`,
   `SMB_USER`, `SMB_PASSWORD` in the `.env`, no `STORAGE_BACKEND`. Docker
   mounted the share itself. Current compose files no longer do that, so the
   only way to keep filing onto that share is to talk SMB directly.
2. **Mount on the Proxmox host**: no SMB credentials in the `.env` (they were
   in a file on the host), `NAS_PATH`, no `STORAGE_BACKEND`. The share is a
   bind mount at `/mnt/nas` inside the container.
3. **Direct SMB**: `STORAGE_BACKEND=smb` or `local`, stated explicitly.

Unlike the old parser this one never refuses to start: a value that does not
parse falls back to its default and is logged. A typo in a variable that is
about to be retired must not keep the service from coming up.
"""
from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass, field

from .config import DEFAULT_BLOCKED_EXTENSIONS, DEFAULT_PRINTABLE_EXTENSIONS, parse_extension_list

logger = logging.getLogger(__name__)

# Every variable an older version read. `update.sh` keeps only what is not in
# this list (plus NAS_PATH where a mount is still in use) when it tidies up.
LEGACY_VARIABLES = (
    "IMAP_HOST", "IMAP_PORT", "IMAP_SSL", "IMAP_USER", "IMAP_PASSWORD", "IMAP_FOLDER",
    "IMAP_PROCESSED_FOLDER", "IMAP_OVERSIZED_FOLDER", "IMAP_MODE", "POLL_INTERVAL_SECONDS",
    "STORAGE_BACKEND", "STORAGE_ROOT", "SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD",
    "SMB_DOMAIN", "SMB_PORT", "SMB_ROOT", "SMB_ENCRYPT", "MAPPING_PATH", "FALLBACK_FOLDER",
    "MATCH_BODY", "FILENAME_PREFIX", "MAX_ATTACHMENT_SIZE_MB", "MAX_MESSAGE_SIZE_MB",
    "MAX_ATTACHMENTS_PER_MESSAGE", "BLOCKED_EXTENSIONS", "QUARANTINE_FOLDER", "DRY_RUN",
    "PRINTING_ENABLED", "PRINT_TIMEOUT_SECONDS", "PRINTABLE_EXTENSIONS", "PRINTER_NAME",
    "PRINTER_DESTINATION", "PRINTER_SERVER", "PRINTER_OPTIONS", "PRINTER_COPIES",
    "WEB_ENABLED", "WEB_PASSWORD",
)


def _text(env: Mapping[str, str], name: str, default: str = "") -> str:
    value = env.get(name)
    return default if value is None else value.strip()


def _flag(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value is None or not value.strip():
        return default
    return value.strip().lower() in ("1", "true", "yes", "on", "ja")


def _number(env: Mapping[str, str], name: str, default: int, minimum: int = 1,
            maximum: int | None = None) -> int:
    raw = env.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except ValueError:
        logger.warning("%s=%r is not a number - using %d", name, raw, default)
        return default
    if value < minimum or (maximum is not None and value > maximum):
        logger.warning("%s=%d is out of range - using %d", name, value, default)
        return default
    return value


def _choice(env: Mapping[str, str], name: str, default: str, allowed: tuple[str, ...]) -> str:
    value = _text(env, name, default).lower() or default
    if value not in allowed:
        logger.warning("%s=%r is not one of %s - using %r", name, value, allowed, default)
        return default
    return value


@dataclass(frozen=True)
class LegacyEnv:
    """The variables of an older `.env`, parsed leniently.

    The attribute names are those of the old `Config`, so the seeding code
    reads the same as it did when it was fed from there.
    """

    imap_host: str = ""
    imap_port: int = 993
    imap_user: str = ""
    imap_password: str = ""
    imap_ssl: bool = True
    imap_folder: str = "INBOX"
    imap_processed_folder: str = ""
    imap_oversized_folder: str = ""
    imap_mode: str = "poll"
    poll_interval: int = 300

    # "smb", "local" or "" (= no archive described at all).
    storage_backend: str = ""
    storage_root: str = "/mnt/nas"
    smb_host: str = ""
    smb_share: str = ""
    smb_user: str = ""
    smb_password: str = ""
    smb_domain: str = ""
    smb_port: int = 445
    smb_root: str = ""
    smb_encrypt: bool = True

    mapping_path: str = "mapping.yaml"
    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    match_body: bool = False
    filename_prefix: str = "date_sender"
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20
    blocked_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_BLOCKED_EXTENSIONS)
    )
    dry_run: bool = False

    printing_enabled: bool = True
    print_timeout: int = 120
    printable_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_PRINTABLE_EXTENSIONS)
    )
    printer_name: str = ""
    printer_destination: str = ""
    printer_server: str = ""
    printer_options: str = ""
    printer_copies: int = 1

    # Which of the old variables were set at all - "the .env says nothing
    # about it" and "the .env says the default" are different things when
    # deciding whether there is anything to carry over.
    present: frozenset[str] = frozenset()

    @property
    def has_mailbox(self) -> bool:
        return bool(self.imap_host and self.imap_user)

    @property
    def has_archive(self) -> bool:
        return self.storage_backend in ("smb", "local")

    @property
    def has_options(self) -> bool:
        """True if any general setting was set in the `.env`."""
        return bool(self.present - {"WEB_ENABLED", "WEB_PASSWORD"})

    @classmethod
    def from_environ(cls, env: Mapping[str, str] | None = None) -> "LegacyEnv":
        env = os.environ if env is None else env
        present = frozenset(
            name for name in LEGACY_VARIABLES if (env.get(name) or "").strip()
        )

        smb = {
            "smb_host": _text(env, "SMB_HOST"),
            "smb_share": _text(env, "SMB_SHARE").strip("/\\"),
            "smb_user": _text(env, "SMB_USER"),
            "smb_password": env.get("SMB_PASSWORD") or "",
        }
        return cls(
            imap_host=_text(env, "IMAP_HOST"),
            imap_port=_number(env, "IMAP_PORT", 993, 1, 65535),
            imap_user=_text(env, "IMAP_USER"),
            imap_password=env.get("IMAP_PASSWORD") or "",
            imap_ssl=_flag(env, "IMAP_SSL", True),
            imap_folder=_text(env, "IMAP_FOLDER", "INBOX") or "INBOX",
            imap_processed_folder=_text(env, "IMAP_PROCESSED_FOLDER"),
            imap_oversized_folder=_text(env, "IMAP_OVERSIZED_FOLDER"),
            imap_mode=_choice(env, "IMAP_MODE", "poll", ("idle", "poll")),
            poll_interval=_number(env, "POLL_INTERVAL_SECONDS", 300, 1),
            storage_backend=_storage_backend(env, smb),
            storage_root=_text(env, "STORAGE_ROOT", "/mnt/nas") or "/mnt/nas",
            smb_domain=_text(env, "SMB_DOMAIN"),
            smb_port=_number(env, "SMB_PORT", 445, 1, 65535),
            smb_root=_text(env, "SMB_ROOT").strip("/"),
            smb_encrypt=_flag(env, "SMB_ENCRYPT", True),
            mapping_path=_text(env, "MAPPING_PATH", "mapping.yaml") or "mapping.yaml",
            fallback_folder=_text(env, "FALLBACK_FOLDER", "unsorted") or "unsorted",
            quarantine_folder=_text(env, "QUARANTINE_FOLDER", "quarantaene") or "quarantaene",
            match_body=_flag(env, "MATCH_BODY", False),
            filename_prefix=_choice(
                env, "FILENAME_PREFIX", "date_sender", ("none", "date", "sender", "date_sender")
            ),
            max_attachment_size_mb=_number(env, "MAX_ATTACHMENT_SIZE_MB", 25),
            max_message_size_mb=_number(env, "MAX_MESSAGE_SIZE_MB", 50),
            max_attachments_per_message=_number(env, "MAX_ATTACHMENTS_PER_MESSAGE", 20),
            blocked_extensions=parse_extension_list(
                env.get("BLOCKED_EXTENSIONS", DEFAULT_BLOCKED_EXTENSIONS)
            ),
            dry_run=_flag(env, "DRY_RUN", False),
            printing_enabled=_flag(env, "PRINTING_ENABLED", True),
            print_timeout=_number(env, "PRINT_TIMEOUT_SECONDS", 120),
            printable_extensions=parse_extension_list(
                env.get("PRINTABLE_EXTENSIONS") or DEFAULT_PRINTABLE_EXTENSIONS
            ),
            printer_name=_text(env, "PRINTER_NAME"),
            printer_destination=_text(env, "PRINTER_DESTINATION"),
            printer_server=_text(env, "PRINTER_SERVER"),
            printer_options=_text(env, "PRINTER_OPTIONS"),
            printer_copies=_number(env, "PRINTER_COPIES", 1, 1, 20),
            present=present,
            **smb,
        )


def _storage_backend(env: Mapping[str, str], smb: dict) -> str:
    """Where the old installation filed to - see the module docstring.

    Getting this wrong is the one mistake an update must not make: a
    generation-1 install treated as "mounted at /mnt/nas" would write every
    attachment into an empty directory inside the container, and lose it with
    the next rebuild.
    """
    explicit = _text(env, "STORAGE_BACKEND").lower()
    if explicit in ("smb", "local"):
        if explicit == "smb" and not (smb["smb_host"] and smb["smb_share"]):
            logger.warning("STORAGE_BACKEND=smb without SMB_HOST/SMB_SHARE - no archive taken over")
            return ""
        return explicit
    if explicit:
        logger.warning("STORAGE_BACKEND=%r is unknown - guessing from the other variables", explicit)

    if all(smb.values()):
        # Generation 1: Docker mounted //SMB_HOST/SMB_SHARE itself.
        return "smb"
    if _text(env, "NAS_PATH") or _text(env, "IMAP_HOST"):
        # Generation 2: the share is bind-mounted into the container.
        return "local"
    # A fresh installation: nothing to take over, the UI sets it up.
    return ""
MAIL2NAS_EOF

# --- mail2nas/migrate.py ---
cat > mail2nas/migrate.py <<'MAIL2NAS_EOF'
"""Bringing an installation of any older version up to this one.

Two steps, both idempotent and both guarded by a flag in the database, so
they run exactly once no matter how often the container restarts:

1. **The `.env`** (`seed_from_legacy`): mailbox, archive, first printer and
   the general settings are written into the database. Runs at startup,
   before anything else; it needs nothing but the environment.

2. **The rule file on the share** (`migrate_rule_file`): an older version kept
   the keyword rules as `mapping.yaml` on the NAS. It is read once, stored in
   the database and renamed on the share to `<name>.migriert`, so nobody keeps
   editing a file that no longer does anything. This needs the archive to be
   reachable, so it is retried until it has happened - and the archiver waits
   for it: filing mail with an empty rule list would put every attachment of
   the first minutes into the fallback folder.
"""
from __future__ import annotations

import logging

from . import accounts as accounts_module
from . import archives as archives_module
from . import printers as printers_module
from .filenames import safe_relative_parts
from .legacy import LegacyEnv
from .mapping import MappingError, RuleStore, rules_from_yaml

logger = logging.getLogger(__name__)

SETTING_MAPPING_PATH = "mapping_path"
SETTING_RULES_MIGRATED = "rules_migrated"
SETTING_RULES_NOTE = "rules_migration_note"
MIGRATED_SUFFIX = ".migriert"


def seed_from_legacy(runtime, legacy: LegacyEnv) -> None:
    """Step 1: carry every value of an older `.env` into the database."""
    settings = runtime.settings
    runtime.options_store.seed(legacy)
    accounts_module.seed_from_config(runtime.accounts, settings, legacy)
    if runtime.printers is not None:
        printers_module.seed_from_config(runtime.printers, settings, legacy)
    if runtime.archives is not None:
        archives_module.seed_from_config(runtime.archives, settings, legacy)
    # Where the old rule file was, for step 2. A path already stored (the old
    # UI could move the file) is the newer statement and wins.
    if not settings.get(SETTING_MAPPING_PATH):
        settings.set(SETTING_MAPPING_PATH, legacy.mapping_path or "mapping.yaml")
    runtime.invalidate_options()


def rules_settled(settings) -> bool:
    """True once there is nothing (left) to take over from the share."""
    return bool(settings.get(SETTING_RULES_MIGRATED))


def migrate_rule_file(settings, store: RuleStore, storage) -> bool:
    """Step 2: take the rule file over from the share. True when settled.

    `storage` is the default archive, or None while there is none. Returns
    False if it should be tried again later (share unreachable), True once
    it has happened or there turned out to be nothing to do.
    """
    if rules_settled(settings):
        return True

    if store.count():
        # Rules already exist in the database (e.g. imported by hand before
        # the share came back). They are the newer statement.
        _settle(settings, "")
        return True

    if storage is None:
        # No archive configured: then there is no share an old file could be
        # on either - this is a fresh installation.
        _settle(settings, "")
        return True

    relative = settings.get(SETTING_MAPPING_PATH) or "mapping.yaml"
    try:
        relative = "/".join(safe_relative_parts(relative))
    except ValueError:
        _settle(settings, f"Der gespeicherte Pfad {relative!r} der alten Mapping-Datei ist ungueltig.")
        return True

    try:
        text = storage.read_text(relative)
    except FileNotFoundError:
        logger.info("No rule file %s on the archive - nothing to take over", relative)
        _settle(settings, "")
        return True
    except Exception as exc:  # noqa: BLE001 - the share may simply be down right now
        logger.warning("Rule file %s not readable yet (%s) - retrying", relative, exc)
        return False

    try:
        rules = rules_from_yaml(text)
    except MappingError as exc:
        # Nothing is lost: the file stays where it is, and the UI says why it
        # was not taken over and offers the import form.
        logger.error("Rule file %s could not be taken over: %s", relative, exc)
        _settle(
            settings,
            f"Die alte Mapping-Datei {relative} konnte nicht uebernommen werden ({exc}). "
            "Sie liegt unveraendert auf der Freigabe - korrigieren und unter "
            "Zuordnungen importieren.",
        )
        return True

    store.save(rules)
    target = relative + MIGRATED_SUFFIX
    try:
        storage.write_text(target, text)
        storage.remove_file(relative)
        where = f"umbenannt in {target}"
    except Exception as exc:  # noqa: BLE001 - the rules are safe, the rename is cosmetics
        logger.warning("Could not rename %s after taking it over (%s)", relative, exc)
        where = "auf der Freigabe liegen geblieben (wird nicht mehr gelesen)"
    logger.info("Took over %d rule(s) from %s", len(rules), relative)
    _settle(
        settings,
        f"{len(rules)} Zuordnung(en) aus {relative} uebernommen. Die Datei wurde {where}; "
        "Zuordnungen werden ab jetzt nur noch hier gepflegt.",
    )
    return True


def _settle(settings, note: str) -> None:
    settings.set(SETTING_RULES_MIGRATED, "1")
    if note:
        settings.set(SETTING_RULES_NOTE, note)


def migration_status(runtime) -> dict:
    """What the update script and the CLI want to know."""
    settings = runtime.settings
    return {
        "options_seeded": runtime.options_store.seeded(),
        "accounts_seeded": bool(settings.get(accounts_module.SETTING_ACCOUNTS_SEEDED)),
        "archives_seeded": bool(settings.get(archives_module.SETTING_ARCHIVES_SEEDED)),
        "printers_seeded": bool(settings.get(printers_module.SETTING_PRINTERS_SEEDED)),
        "rules_migrated": rules_settled(settings),
    }
MAIL2NAS_EOF

# --- mail2nas/cli.py ---
cat > mail2nas/cli.py <<'MAIL2NAS_EOF'
"""A few maintenance commands, for the install and update scripts.

Run inside the container:

    docker compose exec mail2nas python -m mail2nas.cli status
    docker compose exec mail2nas python -m mail2nas.cli password
    docker compose exec mail2nas python -m mail2nas.cli reset-password
    echo '{"host": ...}' | docker compose exec -T mail2nas python -m mail2nas.cli archive-to-smb

Everything else is configured in the web UI; these exist for the handful of
things a script has to do without a browser: find out whether an update has
taken the old configuration over, show the generated first password, get
back in after a forgotten one, and move an installation off a host mount.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys

from .archives import ArchiveError
from .config import Config
from .main import build_runtime
from .migrate import migration_status


def _status(runtime, config) -> int:
    from .web import SETTING_PASSWORD_HASH, read_initial_password

    status = migration_status(runtime)
    default = runtime.default_archive()
    status.update(
        {
            "password_set": bool(runtime.settings.get(SETTING_PASSWORD_HASH)),
            "initial_password_pending": read_initial_password(config.data_dir) is not None,
            "mailboxes": len(runtime.accounts.all()),
            "archives": len(runtime.archives.all()),
            "default_archive": default.location() if default else None,
            "default_archive_backend": default.backend if default else None,
            "rules": runtime.rule_store.count(),
            "printers": len(runtime.printers.all()),
        }
    )
    print(json.dumps(status, indent=2, ensure_ascii=False))
    return 0


def _password(config) -> int:
    from .web import read_initial_password

    password = read_initial_password(config.data_dir)
    if password is None:
        print("Kein Startpasswort mehr hinterlegt - es wurde bereits geaendert.", file=sys.stderr)
        print("Vergessen? python -m mail2nas.cli reset-password", file=sys.stderr)
        return 1
    print(password)
    return 0


def _reset_password(runtime, config) -> int:
    from .web import _write_initial_password, generate_password, set_password

    password = generate_password()
    set_password(runtime.settings, password, config.data_dir)
    _write_initial_password(config.data_dir, password)
    print(password)
    return 0


def _archive_to_smb(runtime) -> int:
    """Switch the mounted-directory archive over to direct SMB.

    For installations from the time the share was mounted on the Proxmox
    host: the host script knows the credentials (they are in a file there)
    and pipes them in as JSON. Nothing changes unless a write test with the
    new settings succeeds - a typo must not cut the archive off.
    """
    try:
        data = json.load(sys.stdin)
    except ValueError as exc:
        print(f"Ungueltige Eingabe: {exc}", file=sys.stderr)
        return 1

    path = data.pop("mount_path", "/mnt/nas")
    candidates = [a for a in runtime.archives.all() if a.backend == "local" and a.path == path]
    if not candidates:
        print(f"Kein Archiv mit gemountetem Verzeichnis {path} - nichts umzustellen.")
        return 2
    archive = candidates[0]

    from .archives import validate

    fields = {
        "name": archive.name if archive.name != "Archiv" else (data.get("share") or archive.name),
        "backend": "smb",
        "host": data.get("host", ""),
        "share": data.get("share", ""),
        "user": data.get("user", ""),
        "password": data.get("password", ""),
        "domain": data.get("domain", ""),
        "port": data.get("port", 445),
        "root": data.get("root", ""),
        "encrypt": data.get("encrypt", True),
        "path": "",
        "enabled": archive.enabled,
    }
    try:
        values = validate(fields)
    except ArchiveError as exc:
        print(f"Zugangsdaten unvollstaendig: {exc}", file=sys.stderr)
        return 1

    from .storage import SmbStorage

    probe = SmbStorage(
        host=values["host"], share=values["share"], user=values["user"],
        password=values["password"], domain=values["domain"] or None, port=values["port"],
        root=values["root"], encrypt=bool(values["encrypt"]),
    )
    try:
        probe.check_writable()
    except BaseException as exc:  # noqa: BLE001 - check_writable reports via SystemExit
        if isinstance(exc, KeyboardInterrupt):
            raise
        print(f"SMB-Test fehlgeschlagen, Archiv bleibt unveraendert: {exc}", file=sys.stderr)
        return 1
    finally:
        probe.close()

    runtime.archives.update(archive.id, **fields)
    print(f"Archiv {archive.name!r} schreibt jetzt direkt auf //{values['host']}/{values['share']}.")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mail2nas.cli", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "command", choices=("status", "password", "reset-password", "archive-to-smb")
    )
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)

    config = Config.from_env()
    if args.command == "password":
        return _password(config)
    runtime = build_runtime(config)
    if args.command == "status":
        return _status(runtime, config)
    if args.command == "reset-password":
        return _reset_password(runtime, config)
    return _archive_to_smb(runtime)


if __name__ == "__main__":
    raise SystemExit(main())
MAIL2NAS_EOF

# --- mail2nas/accounts.py ---
cat > mail2nas/accounts.py <<'MAIL2NAS_EOF'
"""IMAP accounts, stored locally so the web UI can edit them.

Until now there was exactly one mailbox and it came from the environment.
Editing it in the UI - and having more than one - means the configuration has
to live somewhere writable, so it goes into the same SQLite file as the rest
of the local state.

Mailboxes are created in the web UI. An installation updated from a version
that configured its mailbox in the `.env` gets that one carried over once (see
`migrate.py`); after that the `.env` is not read for it any more.

Note this means the state database now holds IMAP passwords in clear text.
It is kept at mode 0600 in a Docker volume, never on the share - see the README.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_ACCOUNTS_SEEDED = "imap_accounts_seeded"


@dataclass(frozen=True)
class Account:
    """One mailbox to watch."""

    id: int
    name: str
    host: str
    port: int
    ssl: bool
    user: str
    password: str
    folder: str
    mode: str  # "idle" or "poll"
    processed_folder: str
    oversized_folder: str
    enabled: bool
    # Print every attachment from this mailbox, regardless of the rules.
    print_attachments: bool = False
    # Printer for this mailbox, as a string key ("" = none configured). A rule
    # that names its own printer overrides it.
    printer: str = ""
    # Off means "print only": attachments are not written to the share.
    archive_attachments: bool = True

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by a mapping rule."""
        return str(self.id)

    def fingerprint(self) -> tuple:
        """Everything a worker thread needs; a change means restart it."""
        return (
            self.host,
            self.port,
            self.ssl,
            self.user,
            self.password,
            self.folder,
            self.mode,
            self.processed_folder,
            self.oversized_folder,
            self.enabled,
            self.print_attachments,
            self.printer,
            self.archive_attachments,
        )


class AccountStore:
    """CRUD for the configured mailboxes.

    Opens a short-lived connection per call: the web UI answers requests on a
    thread pool and the account workers read from their own threads, and one
    sqlite3 connection must not be shared across threads.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS imap_accounts ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "host TEXT NOT NULL, "
                "port INTEGER NOT NULL DEFAULT 993, "
                "ssl INTEGER NOT NULL DEFAULT 1, "
                "user TEXT NOT NULL, "
                "password TEXT NOT NULL, "
                "folder TEXT NOT NULL DEFAULT 'INBOX', "
                "mode TEXT NOT NULL DEFAULT 'poll', "
                "processed_folder TEXT NOT NULL DEFAULT '', "
                "oversized_folder TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )
            _add_missing_columns(conn)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_account(row) -> Account:
        return Account(
            id=row[0],
            name=row[1],
            host=row[2],
            port=row[3],
            ssl=bool(row[4]),
            user=row[5],
            password=row[6],
            folder=row[7],
            mode=row[8],
            processed_folder=row[9],
            oversized_folder=row[10],
            enabled=bool(row[11]),
            print_attachments=bool(row[12]),
            printer=row[13] or "",
            archive_attachments=bool(row[14]),
        )

    _COLUMNS = (
        "id, name, host, port, ssl, user, password, folder, mode, "
        "processed_folder, oversized_folder, enabled, "
        "print_attachments, printer, archive_attachments"
    )

    def all(self) -> list[Account]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM imap_accounts ORDER BY id").fetchall()
        return [self._row_to_account(row) for row in rows]

    def enabled(self) -> list[Account]:
        return [account for account in self.all() if account.enabled]

    def get(self, account_id: int) -> Account | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM imap_accounts WHERE id = ?", (account_id,)
            ).fetchone()
        return self._row_to_account(row) if row else None

    def add(self, **fields) -> int:
        values = _defaults(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO imap_accounts (name, host, port, ssl, user, password, folder, "
                "mode, processed_folder, oversized_folder, enabled, print_attachments, "
                "printer, archive_attachments) "
                "VALUES (:name, :host, :port, :ssl, :user, :password, :folder, :mode, "
                ":processed_folder, :oversized_folder, :enabled, :print_attachments, "
                ":printer, :archive_attachments)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, account_id: int, **fields) -> None:
        current = self.get(account_id)
        if current is None:
            raise KeyError(account_id)
        values = _defaults(
            {
                "name": current.name,
                "host": current.host,
                "port": current.port,
                "ssl": current.ssl,
                "user": current.user,
                "password": current.password,
                "folder": current.folder,
                "mode": current.mode,
                "processed_folder": current.processed_folder,
                "oversized_folder": current.oversized_folder,
                "enabled": current.enabled,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "archive_attachments": current.archive_attachments,
                **fields,
            }
        )
        values["id"] = account_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE imap_accounts SET name = :name, host = :host, port = :port, ssl = :ssl, "
                "user = :user, password = :password, folder = :folder, mode = :mode, "
                "processed_folder = :processed_folder, oversized_folder = :oversized_folder, "
                "enabled = :enabled, print_attachments = :print_attachments, "
                "printer = :printer, archive_attachments = :archive_attachments WHERE id = :id",
                values,
            )

    def delete(self, account_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM imap_accounts WHERE id = ?", (account_id,))


def _add_missing_columns(conn: sqlite3.Connection) -> None:
    """Bring an existing database up to date.

    Printing was added after the table existed, and an update must not require
    re-entering every mailbox - so the columns are added in place, with
    defaults that keep an already-configured install behaving exactly as
    before (nothing printed, everything archived).
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(imap_accounts)")}
    for column, definition in (
        ("print_attachments", "INTEGER NOT NULL DEFAULT 0"),
        ("printer", "TEXT NOT NULL DEFAULT ''"),
        ("archive_attachments", "INTEGER NOT NULL DEFAULT 1"),
    ):
        if column not in existing:
            conn.execute(f"ALTER TABLE imap_accounts ADD COLUMN {column} {definition}")
            logger.info("Added the %s column to the account table", column)


def _defaults(fields: dict) -> dict:
    return {
        "name": str(fields.get("name") or "").strip() or "Postfach",
        "host": str(fields.get("host") or "").strip(),
        "port": int(fields.get("port") or 993),
        "ssl": 1 if fields.get("ssl", True) else 0,
        "user": str(fields.get("user") or "").strip(),
        "password": str(fields.get("password") or ""),
        "folder": str(fields.get("folder") or "INBOX").strip() or "INBOX",
        "mode": "idle" if str(fields.get("mode") or "poll").lower() == "idle" else "poll",
        "processed_folder": str(fields.get("processed_folder") or "").strip(),
        "oversized_folder": str(fields.get("oversized_folder") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
        "print_attachments": 1 if fields.get("print_attachments", False) else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "archive_attachments": 1 if fields.get("archive_attachments", True) else 0,
    }


def seed_from_config(store: AccountStore, settings, config) -> None:
    """Carry the mailbox of an older `.env` over, once.

    `config` is a `LegacyEnv`. A fresh installation has no mailbox in its
    `.env` - it is set up in the web UI - so nothing is created then.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last account in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ACCOUNTS_SEEDED):
        return
    if store.all() or not (config.imap_host and config.imap_user):
        settings.set(SETTING_ACCOUNTS_SEEDED, "1")
        return

    store.add(
        name=config.imap_user or "Postfach",
        host=config.imap_host,
        port=config.imap_port,
        ssl=config.imap_ssl,
        user=config.imap_user,
        password=config.imap_password,
        folder=config.imap_folder,
        mode=config.imap_mode,
        processed_folder=config.imap_processed_folder or "",
        oversized_folder=config.imap_oversized_folder or "",
        enabled=True,
    )
    settings.set(SETTING_ACCOUNTS_SEEDED, "1")
    logger.info("Created the first IMAP account from the configuration (%s)", config.imap_host)
MAIL2NAS_EOF

# --- mail2nas/addresses.py ---
cat > mail2nas/addresses.py <<'MAIL2NAS_EOF'
"""Routing by mail address: what happens to mail sent *to* a given address.

The mapping rules answer "what kind of document is this?" by looking at
keywords. This answers a different question - "who was it sent to, and by
whom?" - and that is what makes a print-by-mail address work: an alias like
`drucker-buero@firma.de` is delivered into the archive mailbox, and everything
addressed to it is printed on the printer that belongs to that alias.

Deliberately independent of the IMAP accounts: aliases usually land in one
mailbox, so a separate account per address would mean a separate IMAP login
per printer. Matching happens on the message instead.

Stored in the same SQLite file as the accounts and printers - the UI has to
be able to edit it, and it references printer ids.
"""
from __future__ import annotations

import fnmatch
import logging
import sqlite3
import threading
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

MAX_NAME_LENGTH = 80
MAX_PATTERN_LENGTH = 200
# Same reasoning as the mapping keywords: the text being matched comes from
# outside, so the pattern may not turn into something expensive.
MAX_WILDCARDS = 5


class AddressError(ValueError):
    """An address rule the user tried to save is not usable."""


def matches_address(pattern: str, address: str) -> bool:
    """True if `address` is covered by `pattern`.

    Three notations, in the order people reach for them:

    * `drucker@firma.de` - exactly this address.
    * `@drucker.firma.de` - every address in that domain.
    * `drucker-*@firma.de` - wildcards, `*` and `?` as usual.

    Case is irrelevant, as it is for mail addresses in practice.
    """
    pattern = (pattern or "").strip().lower()
    address = (address or "").strip().lower()
    if not pattern or not address:
        return False
    if "*" in pattern or "?" in pattern:
        if pattern.count("*") > MAX_WILDCARDS:
            logger.warning("Address pattern %r has too many wildcards - ignoring it", pattern)
            return False
        return fnmatch.fnmatchcase(address, pattern)
    if pattern.startswith("@"):
        return address.endswith(pattern)
    return address == pattern


@dataclass(frozen=True)
class AddressRule:
    """One "mail to this address is handled like this" entry."""

    id: int
    name: str
    recipient: str  # empty = any recipient (then `sender` alone decides)
    sender: str  # empty = any sender
    print_attachments: bool
    printer: str  # printer key; "" = whatever the mailbox is set to
    archive_attachments: bool
    folder: str  # "" = let the keyword rules decide
    archive: str  # which archive the folder is on; "" = the default one
    enabled: bool

    @property
    def key(self) -> str:
        return str(self.id)

    def label(self) -> str:
        where = self.recipient or "(jede Empfaengeradresse)"
        if self.sender:
            where += f" von {self.sender}"
        return f"{self.name} - {where}"

    def matches(self, recipients: Sequence[str], sender: str) -> bool:
        """Does this rule apply to a message?

        Both patterns have to fit when both are set. That is the safe
        direction for something that consumes paper: naming a sender turns
        the rule into "only these people may print here", not into a second,
        independent way to trigger it.
        """
        if self.recipient and not any(matches_address(self.recipient, to) for to in recipients):
            return False
        if self.sender and not matches_address(self.sender, sender):
            return False
        # A rule with neither pattern would match every mail; validate()
        # rejects it, but a hand-edited database must not print everything.
        return bool(self.recipient or self.sender)


class AddressStore:
    """CRUD for the address rules.

    Short-lived connection per call, like the other stores: the web UI and the
    account workers are different threads, and one sqlite3 connection must not
    be shared between them.
    """

    _COLUMNS = (
        "id, name, recipient, sender, print_attachments, printer, "
        "archive_attachments, folder, archive, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS address_rules ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "recipient TEXT NOT NULL DEFAULT '', "
                "sender TEXT NOT NULL DEFAULT '', "
                "print_attachments INTEGER NOT NULL DEFAULT 1, "
                "printer TEXT NOT NULL DEFAULT '', "
                "archive_attachments INTEGER NOT NULL DEFAULT 1, "
                "folder TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )
            _add_missing_columns(conn)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_rule(row) -> AddressRule:
        return AddressRule(
            id=row[0],
            name=row[1],
            recipient=row[2],
            sender=row[3],
            print_attachments=bool(row[4]),
            printer=row[5] or "",
            archive_attachments=bool(row[6]),
            folder=row[7] or "",
            archive=row[8] or "",
            enabled=bool(row[9]),
        )

    def all(self) -> list[AddressRule]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM address_rules ORDER BY id").fetchall()
        return [self._row_to_rule(row) for row in rows]

    def enabled(self) -> list[AddressRule]:
        return [rule for rule in self.all() if rule.enabled]

    def get(self, rule_id: int) -> AddressRule | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM address_rules WHERE id = ?", (rule_id,)
            ).fetchone()
        return self._row_to_rule(row) if row else None

    def match(self, recipients: Iterable[str], sender: str) -> AddressRule | None:
        """The first enabled rule that fits, or None.

        First match wins, like the mapping rules: two aliases that both cover
        a mail is a configuration decision, and printing twice because of it
        would be a surprise.
        """
        addresses = [str(a) for a in recipients]
        for rule in self.enabled():
            if rule.matches(addresses, sender):
                return rule
        return None

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO address_rules (name, recipient, sender, print_attachments, "
                "printer, archive_attachments, folder, archive, enabled) "
                "VALUES (:name, :recipient, :sender, :print_attachments, :printer, "
                ":archive_attachments, :folder, :archive, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, rule_id: int, **fields) -> None:
        current = self.get(rule_id)
        if current is None:
            raise KeyError(rule_id)
        values = validate(
            {
                "name": current.name,
                "recipient": current.recipient,
                "sender": current.sender,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "archive_attachments": current.archive_attachments,
                "folder": current.folder,
                "archive": current.archive,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = rule_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE address_rules SET name = :name, recipient = :recipient, "
                "sender = :sender, print_attachments = :print_attachments, "
                "printer = :printer, archive_attachments = :archive_attachments, "
                "folder = :folder, archive = :archive, enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, rule_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM address_rules WHERE id = ?", (rule_id,))

    def clear_printer(self, printer_key: str) -> int:
        """Drop references to a printer that was deleted.

        Without this the rule would keep pointing at a queue that no longer
        exists and quietly stop printing.
        """
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "UPDATE address_rules SET printer = '' WHERE printer = ?", (str(printer_key),)
            )
            return cursor.rowcount or 0


def _add_missing_columns(conn: sqlite3.Connection) -> None:
    """Bring an existing database up to date.

    Address rules shipped before archives were configurable, and an update
    must not require re-entering them - so the column is added in place, with
    a default that keeps every existing rule on the archive it used.
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(address_rules)")}
    if "archive" not in existing:
        conn.execute("ALTER TABLE address_rules ADD COLUMN archive TEXT NOT NULL DEFAULT ''")
        logger.info("Added the archive column to the address rule table")


def validate(fields: dict) -> dict:
    """Check and normalise what the UI supplies."""
    name = str(fields.get("name") or "").strip()
    recipient = str(fields.get("recipient") or "").strip().lower()
    sender = str(fields.get("sender") or "").strip().lower()
    folder = str(fields.get("folder") or "").strip()

    if not recipient and not sender:
        raise AddressError(
            "Bitte mindestens eine Empfaengeradresse angeben (oder eine Absenderadresse)."
        )
    for pattern, what in ((recipient, "Empfaengeradresse"), (sender, "Absenderadresse")):
        if not pattern:
            continue
        if len(pattern) > MAX_PATTERN_LENGTH:
            raise AddressError(f"Die {what} darf hoechstens {MAX_PATTERN_LENGTH} Zeichen lang sein.")
        if any(char.isspace() for char in pattern) or "," in pattern:
            raise AddressError(
                f"Die {what} darf nur eine einzelne Adresse enthalten "
                "(z. B. drucker@firma.de, @firma.de oder drucker-*@firma.de)."
            )
        if pattern.count("*") > MAX_WILDCARDS:
            raise AddressError(f"Die {what} hat zu viele Platzhalter.")
        if "@" not in pattern:
            raise AddressError(
                f"Die {what} sieht nicht nach einer Adresse aus - das @ fehlt "
                "(eine ganze Domain schreibt man als @firma.de)."
            )
    if len(name) > MAX_NAME_LENGTH:
        raise AddressError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")

    if folder:
        try:
            folder = "/".join(safe_relative_parts(folder))
        except ValueError as exc:
            raise AddressError(f"Der Zielordner ist nicht zulaessig: {exc}") from None

    print_attachments = bool(fields.get("print_attachments", False))
    archive_attachments = bool(fields.get("archive_attachments", True))
    if not print_attachments and not archive_attachments:
        raise AddressError(
            "Ohne Drucken und ohne Ablegen wuerde der Anhang verworfen - "
            "bitte mindestens eines auswaehlen."
        )

    return {
        "name": name or recipient or sender,
        "recipient": recipient,
        "sender": sender,
        "print_attachments": 1 if print_attachments else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "archive_attachments": 1 if archive_attachments else 0,
        "folder": folder,
        "archive": str(fields.get("archive") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
    }
MAIL2NAS_EOF

# --- mail2nas/archives.py ---
cat > mail2nas/archives.py <<'MAIL2NAS_EOF'
"""The archives attachments are filed into - one or several.

Until now there was exactly one archive and it came from the environment.
A household or office often has more than one place things belong: invoices
on the NAS in the office, scans on the one in the workshop, private documents
on a second share of the same box. So an archive becomes a configurable
thing, like the mailboxes and printers before it, and everything that points
somewhere - a mapping rule, a delivery address, a pickup folder - names one.

The first archive is seeded from the `.env`, so an existing installation sees
exactly what it had, under a name, and nothing changes until a second one is
added.

`StorageSet` keeps one live `Storage` per archive. Connections are expensive
(SMB sessions) and the configuration can change while the service runs, so
they are built on demand and rebuilt when the entry behind them changes.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts
from .storage import LocalStorage, SmbStorage, Storage

logger = logging.getLogger(__name__)

SETTING_ARCHIVES_SEEDED = "archives_seeded"

# An empty key means "the default archive" - the first enabled one. Mapping
# files written before archives existed carry no key at all, and a renamed or
# replaced first archive must not silently redirect every rule.
DEFAULT_ARCHIVE = ""

MAX_NAME_LENGTH = 80
BACKENDS = ("smb", "local")


class ArchiveError(ValueError):
    """An archive the user tried to save is not usable."""


class NoArchiveError(RuntimeError):
    """Nothing to file into yet - no archive is configured (or all are paused)."""


@dataclass(frozen=True)
class Archive:
    """One place to file into: an SMB share, or a directory on this machine."""

    id: int
    name: str
    backend: str  # "smb" or "local"
    host: str
    share: str
    user: str
    password: str
    domain: str
    port: int
    root: str  # subfolder below the share root, optional
    encrypt: bool
    path: str  # local backend only
    enabled: bool

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by rules, addresses and pickups."""
        return str(self.id)

    def location(self) -> str:
        if self.backend == "local":
            return self.path
        where = f"//{self.host}/{self.share}"
        return f"{where}/{self.root}" if self.root else where

    def label(self) -> str:
        return f"{self.name} ({self.location()})"

    def fingerprint(self) -> tuple:
        """Everything the connection depends on; a change means rebuild it."""
        return (
            self.backend,
            self.host,
            self.share,
            self.user,
            self.password,
            self.domain,
            self.port,
            self.root,
            self.encrypt,
            self.path,
        )

    def to_storage(self) -> Storage:
        if self.backend == "local":
            return LocalStorage(self.path)
        return SmbStorage(
            host=self.host,
            share=self.share,
            user=self.user,
            password=self.password,
            domain=self.domain or None,
            port=self.port,
            root=self.root,
            encrypt=self.encrypt,
        )


class ArchiveStore:
    """CRUD for the configured archives.

    Short-lived connection per call, like the other stores: the web UI and the
    workers are different threads, and one sqlite3 connection must not be
    shared between them.
    """

    _COLUMNS = (
        "id, name, backend, host, share, user, password, domain, port, root, "
        "encrypt, path, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS archives ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "backend TEXT NOT NULL DEFAULT 'smb', "
                "host TEXT NOT NULL DEFAULT '', "
                "share TEXT NOT NULL DEFAULT '', "
                "user TEXT NOT NULL DEFAULT '', "
                "password TEXT NOT NULL DEFAULT '', "
                "domain TEXT NOT NULL DEFAULT '', "
                "port INTEGER NOT NULL DEFAULT 445, "
                "root TEXT NOT NULL DEFAULT '', "
                "encrypt INTEGER NOT NULL DEFAULT 1, "
                "path TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_archive(row) -> Archive:
        return Archive(
            id=row[0],
            name=row[1],
            backend=row[2],
            host=row[3],
            share=row[4],
            user=row[5],
            password=row[6],
            domain=row[7],
            port=row[8],
            root=row[9],
            encrypt=bool(row[10]),
            path=row[11],
            enabled=bool(row[12]),
        )

    def all(self) -> list[Archive]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM archives ORDER BY id").fetchall()
        return [self._row_to_archive(row) for row in rows]

    def enabled(self) -> list[Archive]:
        return [archive for archive in self.all() if archive.enabled]

    def get(self, archive_id: int) -> Archive | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM archives WHERE id = ?", (archive_id,)
            ).fetchone()
        return self._row_to_archive(row) if row else None

    def by_key(self, key: str) -> Archive | None:
        try:
            return self.get(int(str(key).strip()))
        except (TypeError, ValueError):
            return None

    def default(self) -> Archive | None:
        """The archive used by everything that does not name one."""
        return next(iter(self.enabled()), None)

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO archives (name, backend, host, share, user, password, domain, "
                "port, root, encrypt, path, enabled) VALUES (:name, :backend, :host, :share, "
                ":user, :password, :domain, :port, :root, :encrypt, :path, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, archive_id: int, **fields) -> None:
        current = self.get(archive_id)
        if current is None:
            raise KeyError(archive_id)
        values = validate(
            {
                "name": current.name,
                "backend": current.backend,
                "host": current.host,
                "share": current.share,
                "user": current.user,
                "password": current.password,
                "domain": current.domain,
                "port": current.port,
                "root": current.root,
                "encrypt": current.encrypt,
                "path": current.path,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = archive_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE archives SET name = :name, backend = :backend, host = :host, "
                "share = :share, user = :user, password = :password, domain = :domain, "
                "port = :port, root = :root, encrypt = :encrypt, path = :path, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, archive_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM archives WHERE id = ?", (archive_id,))


def validate(fields: dict) -> dict:
    """Check and normalise what the UI (or the environment) supplies."""
    name = str(fields.get("name") or "").strip()
    backend = str(fields.get("backend") or "smb").strip().lower()
    if backend not in BACKENDS:
        raise ArchiveError("Unbekannte Art von Archiv.")
    if len(name) > MAX_NAME_LENGTH:
        raise ArchiveError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")

    host = str(fields.get("host") or "").strip()
    share = str(fields.get("share") or "").strip().strip("/\\")
    user = str(fields.get("user") or "").strip()
    password = str(fields.get("password") or "")
    domain = str(fields.get("domain") or "").strip()
    path = str(fields.get("path") or "").strip()
    root = str(fields.get("root") or "").strip()

    if root:
        try:
            root = "/".join(safe_relative_parts(root))
        except ValueError as exc:
            raise ArchiveError(f"Der Unterordner ist nicht zulaessig: {exc}") from None

    try:
        port = int(fields.get("port") or 445)
    except (TypeError, ValueError):
        raise ArchiveError("Der Port muss eine Zahl sein.") from None
    if not 1 <= port <= 65535:
        raise ArchiveError("Der Port muss zwischen 1 und 65535 liegen.")

    if backend == "smb":
        if not host:
            raise ArchiveError("Bitte den Server (NAS) angeben.")
        if not share:
            raise ArchiveError("Bitte den Namen der Freigabe angeben.")
        if not user:
            raise ArchiveError("Bitte den SMB-Benutzer angeben.")
        if not password:
            raise ArchiveError("Bitte das SMB-Passwort angeben.")
    else:
        if not path:
            raise ArchiveError("Bitte das Verzeichnis angeben, in dem das Share gemountet ist.")
        if not path.startswith("/"):
            raise ArchiveError("Das Verzeichnis muss ein absoluter Pfad sein (z. B. /mnt/nas).")

    default_name = share or Path(path).name or host or "Archiv"
    return {
        "name": name or default_name,
        "backend": backend,
        "host": host,
        "share": share,
        "user": user,
        "password": password,
        "domain": domain,
        "port": port,
        "root": root,
        "encrypt": 1 if fields.get("encrypt", True) else 0,
        "path": path,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }


def seed_from_config(store: ArchiveStore, settings, config) -> None:
    """Carry the archive of an older `.env` over, once.

    `config` is a `LegacyEnv`, which has already worked out which generation
    of installation this is (see `legacy.py`). A fresh installation describes
    no archive at all - it is set up in the web UI - so nothing is created.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last archive in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ARCHIVES_SEEDED):
        return
    if store.all() or config.storage_backend not in BACKENDS:
        settings.set(SETTING_ARCHIVES_SEEDED, "1")
        return

    try:
        if config.storage_backend == "smb":
            store.add(
                name=config.smb_share or config.smb_host,
                backend="smb",
                host=config.smb_host,
                share=config.smb_share,
                user=config.smb_user,
                password=config.smb_password,
                domain=config.smb_domain,
                port=config.smb_port,
                root=config.smb_root,
                encrypt=config.smb_encrypt,
            )
        else:
            store.add(name="Archiv", backend="local", path=config.storage_root)
    except ArchiveError as exc:
        # E.g. an SMB password that was never filled in. The UI shows that no
        # archive exists; better than a half-configured one.
        logger.error("The archive from the .env is not usable (%s) - set it up in the web UI", exc)
    settings.set(SETTING_ARCHIVES_SEEDED, "1")
    logger.info("Took the archive over from the .env")


class StorageSet:
    """Live `Storage` objects for the configured archives.

    Built on demand and cached: an SMB session is not something to set up per
    attachment. The cache key includes the archive's settings, so changing a
    password in the UI takes effect on the next write instead of after a
    restart.
    """

    def __init__(self, archives: ArchiveStore | None, fallback: Storage | None = None):
        self._archives = archives
        self._fallback = fallback
        self._cache: dict[str, tuple[tuple, Storage]] = {}
        self._lock = threading.Lock()

    @property
    def fallback(self) -> Storage | None:
        """A fixed storage used when no archive store is attached (tests)."""
        return self._fallback

    def archive_for(self, key: str) -> Archive | None:
        """The archive a key refers to, or the default one."""
        if self._archives is None:
            return None
        if key and key != DEFAULT_ARCHIVE:
            archive = self._archives.by_key(key)
            if archive is None:
                logger.warning("Archive %r is configured somewhere but no longer exists", key)
            elif not archive.enabled:
                logger.warning("Archive %r is paused - filing into the default archive", archive.name)
            else:
                return archive
        return self._archives.default()

    def get(self, key: str = DEFAULT_ARCHIVE) -> Storage:
        """The storage behind `key`, falling back to the default archive."""
        archive = self.archive_for(key)
        if archive is None:
            if self._fallback is None:
                raise NoArchiveError("Es ist noch kein (aktives) Archiv eingerichtet.")
            return self._fallback
        with self._lock:
            cached = self._cache.get(archive.key)
            if cached is not None and cached[0] == archive.fingerprint():
                return cached[1]
            if cached is not None:
                logger.info("Archive %r changed - reconnecting", archive.name)
                self._close(cached[1])
            storage = archive.to_storage()
            self._cache[archive.key] = (archive.fingerprint(), storage)
            return storage

    def default(self) -> Storage:
        return self.get(DEFAULT_ARCHIVE)

    def label_for(self, key: str) -> str:
        archive = self.archive_for(key)
        if archive is not None:
            return archive.name
        return self._fallback.description if self._fallback is not None else "-"

    def close(self) -> None:
        with self._lock:
            for _, storage in self._cache.values():
                self._close(storage)
            self._cache.clear()

    @staticmethod
    def _close(storage: Storage) -> None:
        try:
            storage.close()
        except Exception:  # noqa: BLE001 - closing a broken session must not raise
            logger.debug("Could not close a storage connection", exc_info=True)
MAIL2NAS_EOF

# --- mail2nas/pickups.py ---
cat > mail2nas/pickups.py <<'MAIL2NAS_EOF'
"""Folders that devices drop documents into.

Multifunction printers can usually either mail a scan or write it straight
onto an SMB share ("Scan to Folder"). The second way never involves a mailbox
at all, so nothing in the IMAP path sees it - but the documents should end up
filed by exactly the same rules, and optionally printed.

A pickup folder is therefore the third way in, next to mail and delivery
addresses: mail2nas watches it, waits until a file has stopped changing, and
moves it into the archive.

Moving, not copying: the pickup folder is the device's outbox. Leaving the
original behind would re-import it on every single cycle.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

MAX_NAME_LENGTH = 80
# How often the watched folders are listed. Cheap locally, a network round
# trip over SMB - so not on every supervisor pass.
PICKUP_INTERVAL = 30
# Devices like to create one subfolder per user or scan profile; that is worth
# following, an unbounded tree is not.
MAX_DEPTH = 5


class PickupError(ValueError):
    """A pickup folder the user tried to save is not usable."""


@dataclass(frozen=True)
class Pickup:
    """One watched folder, and what happens to what turns up in it."""

    id: int
    name: str
    archive: str  # archive the folder is on ("" = the default one)
    folder: str  # relative path of the watched folder
    target_archive: str  # where the documents go ("" = the default one)
    target_folder: str  # "" = let the keyword rules decide
    print_attachments: bool
    printer: str
    enabled: bool

    @property
    def key(self) -> str:
        return str(self.id)

    def label(self) -> str:
        return f"{self.name} ({self.folder})"

    @property
    def has_fixed_target(self) -> bool:
        return bool(self.target_folder.strip())

    @property
    def parts(self) -> tuple[str, ...]:
        return safe_relative_parts(self.folder)

    def rule_scope(self) -> str:
        """The account id a pickup files under.

        A document dropped into a folder did not arrive through any mailbox,
        so only rules that apply to "all accounts" may claim it. Account ids
        are numbers, so this can never collide with a real one.
        """
        return f"pickup:{self.id}"

    def files_into_itself(self) -> bool:
        """True if the target sits inside the watched folder.

        That would re-import the same document for ever, so it is refused when
        saving and skipped at runtime.
        """
        if not self.has_fixed_target or (self.target_archive or "") != (self.archive or ""):
            return False
        try:
            source = safe_relative_parts(self.folder)
            target = safe_relative_parts(self.target_folder)
        except ValueError:
            return False
        return target[: len(source)] == source


class PickupStore:
    """CRUD for the watched folders."""

    _COLUMNS = (
        "id, name, archive, folder, target_archive, target_folder, "
        "print_attachments, printer, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS pickup_folders ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "archive TEXT NOT NULL DEFAULT '', "
                "folder TEXT NOT NULL, "
                "target_archive TEXT NOT NULL DEFAULT '', "
                "target_folder TEXT NOT NULL DEFAULT '', "
                "print_attachments INTEGER NOT NULL DEFAULT 0, "
                "printer TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_pickup(row) -> Pickup:
        return Pickup(
            id=row[0],
            name=row[1],
            archive=row[2] or "",
            folder=row[3],
            target_archive=row[4] or "",
            target_folder=row[5] or "",
            print_attachments=bool(row[6]),
            printer=row[7] or "",
            enabled=bool(row[8]),
        )

    def all(self) -> list[Pickup]:
        with self._connect() as conn:
            rows = conn.execute(
                f"SELECT {self._COLUMNS} FROM pickup_folders ORDER BY id"
            ).fetchall()
        return [self._row_to_pickup(row) for row in rows]

    def enabled(self) -> list[Pickup]:
        return [pickup for pickup in self.all() if pickup.enabled]

    def get(self, pickup_id: int) -> Pickup | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM pickup_folders WHERE id = ?", (pickup_id,)
            ).fetchone()
        return self._row_to_pickup(row) if row else None

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO pickup_folders (name, archive, folder, target_archive, "
                "target_folder, print_attachments, printer, enabled) "
                "VALUES (:name, :archive, :folder, :target_archive, :target_folder, "
                ":print_attachments, :printer, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, pickup_id: int, **fields) -> None:
        current = self.get(pickup_id)
        if current is None:
            raise KeyError(pickup_id)
        values = validate(
            {
                "name": current.name,
                "archive": current.archive,
                "folder": current.folder,
                "target_archive": current.target_archive,
                "target_folder": current.target_folder,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = pickup_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE pickup_folders SET name = :name, archive = :archive, "
                "folder = :folder, target_archive = :target_archive, "
                "target_folder = :target_folder, print_attachments = :print_attachments, "
                "printer = :printer, enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, pickup_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM pickup_folders WHERE id = ?", (pickup_id,))

    def clear_printer(self, printer_key: str) -> int:
        """Drop references to a printer that was deleted."""
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "UPDATE pickup_folders SET print_attachments = 0, printer = '' "
                "WHERE printer = ?",
                (str(printer_key),),
            )
            return cursor.rowcount or 0


def validate(fields: dict) -> dict:
    """Check and normalise what the UI supplies."""
    name = str(fields.get("name") or "").strip()
    folder = str(fields.get("folder") or "").strip()
    target_folder = str(fields.get("target_folder") or "").strip()

    if len(name) > MAX_NAME_LENGTH:
        raise PickupError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")
    if not folder:
        raise PickupError("Bitte den Ordner angeben, in den das Geraet die Scans legt.")

    cleaned = {}
    for key, value in (("folder", folder), ("target_folder", target_folder)):
        if not value:
            cleaned[key] = ""
            continue
        try:
            cleaned[key] = "/".join(safe_relative_parts(value))
        except ValueError as exc:
            what = "Abholordner" if key == "folder" else "Zielordner"
            raise PickupError(f"Der {what} ist nicht zulaessig: {exc}") from None

    values = {
        "name": name or cleaned["folder"],
        "archive": str(fields.get("archive") or "").strip(),
        "folder": cleaned["folder"],
        "target_archive": str(fields.get("target_archive") or "").strip(),
        "target_folder": cleaned["target_folder"],
        "print_attachments": 1 if fields.get("print_attachments", False) else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
    }

    candidate = Pickup(id=0, **{**values, "print_attachments": bool(values["print_attachments"]),
                                "enabled": bool(values["enabled"])})
    if candidate.files_into_itself():
        raise PickupError(
            "Der Zielordner liegt im Abholordner - die Dokumente wuerden immer wieder "
            "eingelesen. Bitte einen Zielordner ausserhalb waehlen."
        )
    return values
MAIL2NAS_EOF

# --- mail2nas/printers.py ---
cat > mail2nas/printers.py <<'MAIL2NAS_EOF'
"""Printers, stored locally so the web UI can manage them centrally.

A printer is configured once - here - and then only *referenced* everywhere
else: a mailbox picks one from a dropdown, a mapping rule picks one from a
dropdown. That way the queue name, the CUPS server and the paper options live
in exactly one place, and changing them does not mean editing every rule.

Same storage as the IMAP accounts (the SQLite file next to the state), for the
same reason: it has to be writable, survive updates, and be editable from the
UI. Unlike the accounts this holds no credentials - printing goes through the
local CUPS client, which does its own authentication if the server needs any.
"""
from __future__ import annotations

import logging
import shlex
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_PRINTERS_SEEDED = "printers_seeded"

MAX_NAME_LENGTH = 80
MAX_DESTINATION_LENGTH = 128
MAX_OPTIONS_LENGTH = 200
MAX_COPIES = 20


class PrinterError(ValueError):
    """A printer the user tried to save is not usable."""


@dataclass(frozen=True)
class Printer:
    """One print queue."""

    id: int
    name: str
    destination: str  # CUPS queue name, i.e. `lp -d <destination>`
    server: str  # optional CUPS server "host" or "host:port"; empty = local cupsd
    options: str  # extra lp options, e.g. "media=A4 sides=two-sided-long-edge"
    copies: int
    enabled: bool

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by an account or a mapping rule."""
        return str(self.id)

    @property
    def option_list(self) -> list[str]:
        """The options as separate `-o` arguments."""
        return shlex.split(self.options) if self.options.strip() else []

    def label(self) -> str:
        where = f" @ {self.server}" if self.server else ""
        return f"{self.name} ({self.destination}{where})"


class PrinterStore:
    """CRUD for the configured printers.

    Opens a short-lived connection per call, like `AccountStore`: the web UI
    answers requests on a thread pool and the account workers read from their
    own threads, and one sqlite3 connection must not be shared across threads.
    """

    _COLUMNS = "id, name, destination, server, options, copies, enabled"

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS printers ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "destination TEXT NOT NULL, "
                "server TEXT NOT NULL DEFAULT '', "
                "options TEXT NOT NULL DEFAULT '', "
                "copies INTEGER NOT NULL DEFAULT 1, "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_printer(row) -> Printer:
        return Printer(
            id=row[0],
            name=row[1],
            destination=row[2],
            server=row[3],
            options=row[4],
            copies=row[5],
            enabled=bool(row[6]),
        )

    def all(self) -> list[Printer]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM printers ORDER BY id").fetchall()
        return [self._row_to_printer(row) for row in rows]

    def enabled(self) -> list[Printer]:
        return [printer for printer in self.all() if printer.enabled]

    def get(self, printer_id: int) -> Printer | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM printers WHERE id = ?", (printer_id,)
            ).fetchone()
        return self._row_to_printer(row) if row else None

    def by_key(self, key: str) -> Printer | None:
        """Look a printer up by the string id an account or rule stores."""
        try:
            printer_id = int(str(key).strip())
        except (TypeError, ValueError):
            return None
        return self.get(printer_id)

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO printers (name, destination, server, options, copies, enabled) "
                "VALUES (:name, :destination, :server, :options, :copies, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, printer_id: int, **fields) -> None:
        current = self.get(printer_id)
        if current is None:
            raise KeyError(printer_id)
        values = validate(
            {
                "name": current.name,
                "destination": current.destination,
                "server": current.server,
                "options": current.options,
                "copies": current.copies,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = printer_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE printers SET name = :name, destination = :destination, "
                "server = :server, options = :options, copies = :copies, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, printer_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM printers WHERE id = ?", (printer_id,))


def validate(fields: dict) -> dict:
    """Check and normalise what the UI (or the environment) supplies.

    The values end up as arguments to the `lp` binary. That call never goes
    through a shell, so this is not about quoting - it is about catching typos
    early and refusing values (newlines, leading dashes) that would turn into
    something other than what was typed.
    """
    name = str(fields.get("name") or "").strip()
    destination = str(fields.get("destination") or "").strip()
    server = str(fields.get("server") or "").strip()
    options = " ".join(str(fields.get("options") or "").split())

    if not destination:
        raise PrinterError("Bitte den Namen der Druckerwarteschlange angeben.")
    if len(destination) > MAX_DESTINATION_LENGTH:
        raise PrinterError(f"Die Warteschlange darf hoechstens {MAX_DESTINATION_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in destination) or destination.startswith("-"):
        raise PrinterError(
            "Die Warteschlange darf keine Leerzeichen enthalten und nicht mit '-' beginnen "
            "(so heisst sie auch in CUPS)."
        )
    if len(name) > MAX_NAME_LENGTH:
        raise PrinterError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in server) or server.startswith("-"):
        raise PrinterError("Der CUPS-Server darf keine Leerzeichen enthalten (z. B. cups.lan:631).")
    if len(options) > MAX_OPTIONS_LENGTH:
        raise PrinterError(f"Die Optionen duerfen hoechstens {MAX_OPTIONS_LENGTH} Zeichen lang sein.")

    try:
        option_list = shlex.split(options) if options else []
    except ValueError as exc:
        raise PrinterError(f"Die Optionen sind nicht lesbar: {exc}") from None
    for option in option_list:
        if option.startswith("-"):
            raise PrinterError(
                f"Option {option!r}: nur der Teil hinter -o angeben, z. B. media=A4."
            )

    try:
        copies = int(fields.get("copies") or 1)
    except (TypeError, ValueError):
        raise PrinterError("Die Anzahl der Kopien muss eine Zahl sein.") from None
    if not 1 <= copies <= MAX_COPIES:
        raise PrinterError(f"Die Anzahl der Kopien muss zwischen 1 und {MAX_COPIES} liegen.")

    return {
        "name": name or destination,
        "destination": destination,
        "server": server,
        "options": options,
        "copies": copies,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }


def seed_from_config(store: PrinterStore, settings, config) -> None:
    """Create the first printer from the environment, once.

    Same deal as the IMAP accounts: an install that configured a printer in
    the `.env` gets it without re-entering anything, and deleting it in the UI
    does not resurrect it on the next restart.
    """
    if settings.get(SETTING_PRINTERS_SEEDED):
        return
    if store.all() or not config.printer_destination:
        settings.set(SETTING_PRINTERS_SEEDED, "1")
        return

    try:
        store.add(
            name=config.printer_name or config.printer_destination,
            destination=config.printer_destination,
            server=config.printer_server,
            options=config.printer_options,
            copies=config.printer_copies,
            enabled=True,
        )
    except PrinterError as exc:
        logger.error("PRINTER_DESTINATION is not usable (%s) - no printer was created", exc)
        return
    settings.set(SETTING_PRINTERS_SEEDED, "1")
    logger.info("Created the first printer from the configuration (%s)", config.printer_destination)
MAIL2NAS_EOF

# --- mail2nas/printing.py ---
cat > mail2nas/printing.py <<'MAIL2NAS_EOF'
"""Sending attachments to a printer.

Printing goes through the `lp` client from CUPS rather than through a Python
IPP library: every NAS-adjacent printer setup already has a CUPS server (or a
printer that speaks IPP and can be added to one), `lp` handles the driver and
format conversion side, and it means no long-lived printer connection has to
be maintained inside a service whose real job is archiving mail.

Two rules the rest of the code depends on:

* **Nothing is printed that was quarantined.** That decision is made in the
  archiver; this module only ever sees what it is handed. What it does check
  is the file type: an unknown format sent to a queue produces a stack of
  garbage paper, so only known-printable extensions are spooled.
* **A failing printer never fails the archiving.** Paper is the copy, the
  share is the archive. Every error is logged and swallowed by
  `PrintService.send`, so an offline printer cannot stop mail from being
  filed - or, worse, cause the same mail to be processed again and again.
"""
from __future__ import annotations

import logging
import os
import subprocess
import tempfile

from .config import DEFAULT_PRINTABLE_EXTENSIONS
from .filenames import extension_of, sanitize_filename
from .printers import Printer, PrinterStore

logger = logging.getLogger(__name__)

# The job title shows up in the CUPS queue. Keep it short and free of control
# characters - it is built from an attacker-supplied filename.
MAX_TITLE_LENGTH = 80


class PrintError(RuntimeError):
    """A print job could not be handed to CUPS."""


def parse_extensions(raw: str) -> frozenset[str]:
    return frozenset(ext.strip().lower().lstrip(".") for ext in raw.split(",") if ext.strip())


def job_title(prefix: str, filename: str) -> str:
    title = f"{prefix}: {filename}" if prefix else filename
    title = "".join(char for char in title if char.isprintable())
    return title[:MAX_TITLE_LENGTH] or "mail2nas"


def build_command(printer: Printer, path: str, title: str, lp_binary: str = "lp") -> list[str]:
    """Build the `lp` invocation for one job.

    Split out from the call so the command can be asserted on in tests without
    a printer anywhere near. Note the arguments are passed to `lp` directly -
    there is no shell involved, so nothing here needs quoting.
    """
    command = [lp_binary]
    if printer.server:
        command += ["-h", printer.server]
    command += ["-d", printer.destination, "-t", title]
    if printer.copies > 1:
        command += ["-n", str(printer.copies)]
    for option in printer.option_list:
        command += ["-o", option]
    # "--" so a filename can never be read as an option, whatever it is called.
    return [*command, "--", path]


class Spooler:
    """Hands bytes to CUPS, one temporary file per job."""

    def __init__(
        self,
        lp_binary: str = "lp",
        timeout: int = 120,
        printable_extensions: frozenset[str] = frozenset(),
        dry_run: bool = False,
        options=None,
    ):
        self._lp_binary = lp_binary
        self._timeout_value = timeout
        self._printable_value = printable_extensions
        self._dry_run_value = dry_run
        # A callable returning the current Options. When given, timeout,
        # printable formats and the test mode follow the settings page live
        # instead of what was passed in here.
        self._options = options

    @property
    def _timeout(self) -> int:
        return self._options().print_timeout if self._options else self._timeout_value

    @property
    def _dry_run(self) -> bool:
        return self._options().dry_run if self._options else self._dry_run_value

    @property
    def printable_extensions(self) -> frozenset[str]:
        chosen = self._options().printable_extensions if self._options else self._printable_value
        # Empty means "the standard list", not "nothing": a printer that
        # silently never prints anything is not what anyone clearing the
        # field meant.
        return chosen or parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS)

    def can_print(self, filename: str) -> bool:
        return extension_of(sanitize_filename(filename)) in self.printable_extensions

    def print_bytes(self, printer: Printer, data: bytes, filename: str, title: str = "") -> str:
        """Spool `data` to `printer`. Returns what `lp` reported, for the log.

        Raises PrintError for anything that went wrong, including a missing
        `lp` binary - which is the most likely failure on a container that was
        built before printing existed.
        """
        extension = extension_of(sanitize_filename(filename))
        return self._spool(printer, data, extension, title or job_title("", filename))

    def print_test_page(self, printer: Printer) -> str:
        """Print a page that says where it came from, to verify a queue."""
        page = (
            "mail2nas - Testseite\n"
            "====================\n\n"
            f"Drucker: {printer.label()}\n"
            f"Optionen: {printer.options or '(keine)'}\n"
            f"Kopien: {printer.copies}\n\n"
            "Kommt diese Seite an, funktioniert die Warteschlange.\n"
        )
        return self._spool(printer, page.encode("utf-8"), "txt", "mail2nas Testseite")

    def _spool(self, printer: Printer, data: bytes, extension: str, title: str) -> str:
        if self._dry_run:
            logger.info("[dry-run] would print %r on %s", title, printer.label())
            return "dry-run"

        suffix = f".{extension}" if extension else ""
        handle, path = tempfile.mkstemp(prefix="mail2nas-print-", suffix=suffix)
        try:
            # The attachment is untrusted content sitting in a shared temp
            # directory until CUPS has picked it up, so nobody else may read it.
            os.chmod(path, 0o600)
            with os.fdopen(handle, "wb") as fh:
                fh.write(data)
            return self._run(build_command(printer, path, title, self._lp_binary))
        finally:
            try:
                os.unlink(path)
            except OSError:  # pragma: no cover - only if something else removed it
                logger.debug("Could not remove the temporary print file %s", path, exc_info=True)

    def _run(self, command: list[str]) -> str:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=self._timeout, check=False
            )
        except FileNotFoundError:
            raise PrintError(
                f"{self._lp_binary} nicht gefunden - im Container fehlt das Paket cups-client "
                "(oder LP_BINARY zeigt auf den falschen Pfad)."
            ) from None
        except subprocess.TimeoutExpired:
            raise PrintError(
                f"Der Druckauftrag wurde nach {self._timeout}s abgebrochen - "
                "antwortet der CUPS-Server?"
            ) from None
        except OSError as exc:
            raise PrintError(f"Druckauftrag fehlgeschlagen: {exc}") from exc

        if result.returncode != 0:
            message = (result.stderr or result.stdout or "").strip()
            raise PrintError(message or f"{self._lp_binary} endete mit Code {result.returncode}")
        return (result.stdout or "").strip()


class PrintService:
    """Which printer a job goes to, and the promise that it never raises.

    `printer_for` implements the precedence the UI documents: the most
    specific setting wins. A mapping rule that names a printer beats the
    mailbox default, which beats "no printer configured" (nothing is printed,
    and it is logged - silently dropping paper someone asked for is worse than
    a log line).
    """

    def __init__(self, printers: PrinterStore, spooler: Spooler):
        self._printers = printers
        self._spooler = spooler

    @property
    def spooler(self) -> Spooler:
        return self._spooler

    def configured(self) -> bool:
        return bool(self._printers.enabled())

    def printer_for(self, *keys: str) -> Printer | None:
        """First enabled printer among `keys`, which may contain blanks."""
        for key in keys:
            if not key or str(key) in ("0", "None"):
                continue
            printer = self._printers.by_key(key)
            if printer is None:
                logger.warning("Printer %r is configured somewhere but no longer exists", key)
                continue
            if not printer.enabled:
                logger.warning("Printer %r is paused - not printing on it", printer.label())
                continue
            return printer
        return None

    def send(self, printer: Printer, data: bytes, filename: str, title: str = "") -> bool:
        """Print, reporting failures rather than raising them.

        Returns True if CUPS accepted the job. The archiver treats a False as
        "the paper copy did not happen" and carries on: the attachment is
        already on the share, and re-processing the mail to retry the print
        would duplicate the archived file.
        """
        if not self._spooler.can_print(filename):
            logger.warning(
                "Not printing %r on %s: %s is not in PRINTABLE_EXTENSIONS",
                filename,
                printer.label(),
                extension_of(sanitize_filename(filename)) or "(no extension)",
            )
            return False
        try:
            reply = self._spooler.print_bytes(printer, data, filename, title)
        except PrintError as exc:
            logger.error("Printing %r on %s failed: %s", filename, printer.label(), exc)
            return False
        logger.info("Printed %r on %s%s", filename, printer.label(), f" ({reply})" if reply else "")
        return True


def from_config(config, printers: PrinterStore, options=None) -> PrintService:
    """Build the print service: binaries from the config, the rest live from `options`."""
    return PrintService(printers, Spooler(lp_binary=config.lp_binary, options=options))
MAIL2NAS_EOF

# --- mail2nas/discovery.py ---
cat > mail2nas/discovery.py <<'MAIL2NAS_EOF'
"""Finding printers that are already on the network.

Two sources, because there are two kinds of "printer" in this context:

* **Queues on a CUPS server** (`lpstat -v`). These are ready to use: their
  name is exactly what goes into a printer's "Warteschlange", and printing
  works the moment it is saved.
* **Devices advertising themselves via mDNS/DNS-SD** (`_ipp._tcp` and
  friends), which is how AirPrint/driverless printers announce their
  presence. These are found even when nothing has been set up yet - but a
  raw device is not a CUPS queue, so the UI says how to turn it into one.

Everything here is best-effort and bounded: discovery runs inside a web
request, and an unreachable CUPS server or a network that swallows multicast
must return an empty list quickly rather than hang the page.
"""
from __future__ import annotations

import logging
import socket
import struct
import subprocess
import time
from dataclasses import dataclass

logger = logging.getLogger(__name__)

MDNS_ADDRESS = "224.0.0.251"
MDNS_PORT = 5353
# The services a network printer announces itself under. _pdl-datastream is
# raw port-9100 printing, which many devices offer alongside IPP.
MDNS_SERVICES = ("_ipp._tcp.local", "_ipps._tcp.local", "_pdl-datastream._tcp.local")
MAX_RESPONSE_BYTES = 9000
MAX_NAME_JUMPS = 20

TYPE_A = 1
TYPE_PTR = 12
TYPE_TXT = 16
TYPE_SRV = 33
# Unicast-response bit (RFC 6762 5.4): without it responders answer by
# multicast to port 5353, which a one-shot client is not listening on.
QCLASS_IN_UNICAST = 0x8001


@dataclass(frozen=True)
class Found:
    """One discovered printer, in the terms the printer form needs."""

    name: str
    destination: str  # queue name / IPP resource
    server: str  # "host" or "host:port"; empty = the local CUPS server
    source: str  # "cups" or "mdns"
    detail: str = ""  # device URI or model, shown to the user

    @property
    def ready_to_use(self) -> bool:
        """True if this can be printed on as-is (a real CUPS queue)."""
        return self.source == "cups"

    def lpadmin_command(self) -> str:
        """How to turn a discovered device into a CUPS queue, for copy & paste."""
        uri = self.detail or f"ipp://{self.server}/{self.destination}"
        queue = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in self.name) or "drucker"
        return f"lpadmin -p {queue} -v {uri} -E -m everywhere"


# --- CUPS ------------------------------------------------------------------


def cups_queues(server: str = "", lpstat_binary: str = "lpstat", timeout: int = 10) -> list[Found]:
    """Ask a CUPS server which queues it has.

    `lpstat -v` is used rather than `-e`: it names the device behind each
    queue, which is what tells two similarly named queues apart.
    """
    command = [lpstat_binary]
    if server.strip():
        command += ["-h", server.strip()]
    command += ["-v"]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError:
        raise DiscoveryError(
            f"{lpstat_binary} nicht gefunden - im Container fehlt das Paket cups-client."
        ) from None
    except subprocess.TimeoutExpired:
        raise DiscoveryError(
            f"Der CUPS-Server hat nicht innerhalb von {timeout}s geantwortet."
        ) from None
    except OSError as exc:
        raise DiscoveryError(f"CUPS-Abfrage fehlgeschlagen: {exc}") from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip()
        raise DiscoveryError(message or f"{lpstat_binary} endete mit Code {result.returncode}")

    return parse_lpstat(result.stdout or "", server.strip())


def parse_lpstat(output: str, server: str = "") -> list[Found]:
    """Turn `lpstat -v` output into printers.

    Lines look like::

        device for Buero_MFP: ipp://192.168.1.50:631/ipp/print
        Gerät für Flur: socket://192.168.1.51:9100

    The prefix is localised, so the colon is what is parsed, not the words.
    """
    found: list[Found] = []
    for line in output.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        head, _, uri = line.partition(":")
        # "device for NAME" / "Gerät für NAME" - the queue is the last word.
        queue = head.split()[-1] if head.split() else ""
        uri = uri.strip()
        if not queue or not uri:
            continue
        found.append(
            Found(name=queue, destination=queue, server=server, source="cups", detail=uri)
        )
    return found


class DiscoveryError(RuntimeError):
    """Discovery could not be carried out (as opposed to finding nothing)."""


# --- mDNS / DNS-SD ----------------------------------------------------------


def _encode_name(name: str) -> bytes:
    parts = [label.encode("utf-8") for label in name.strip(".").split(".")]
    return b"".join(bytes([len(p)]) + p for p in parts) + b"\x00"


def _query(service: str) -> bytes:
    header = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + _encode_name(service) + struct.pack(">HH", TYPE_PTR, QCLASS_IN_UNICAST)


def _read_name(data: bytes, offset: int) -> tuple[str, int]:
    """Decode a (possibly compressed) DNS name. Returns (name, offset after it)."""
    labels: list[str] = []
    jumps = 0
    after: int | None = None
    while True:
        if offset >= len(data):
            raise ValueError("truncated name")
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length & 0xC0 == 0xC0:  # compression pointer
            if offset + 1 >= len(data):
                raise ValueError("truncated pointer")
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if after is None:
                after = offset + 2
            jumps += 1
            if jumps > MAX_NAME_JUMPS or pointer >= len(data):
                raise ValueError("name pointer loop")
            offset = pointer
            continue
        start = offset + 1
        offset = start + length
        if offset > len(data):
            raise ValueError("truncated label")
        labels.append(data[start:offset].decode("utf-8", "replace"))
    return ".".join(labels), (after if after is not None else offset)


def _read_records(data: bytes) -> list[tuple[str, int, bytes, int]]:
    """Every resource record as (name, type, rdata, rdata offset)."""
    if len(data) < 12:
        return []
    _, _, questions, answers, authority, additional = struct.unpack(">HHHHHH", data[:12])
    offset = 12
    for _ in range(questions):
        _, offset = _read_name(data, offset)
        offset += 4
    records = []
    for _ in range(answers + authority + additional):
        name, offset = _read_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _rclass, _ttl, rdlength = struct.unpack(">HHIH", data[offset : offset + 10])
        offset += 10
        rdata = data[offset : offset + rdlength]
        records.append((name, rtype, rdata, offset))
        offset += rdlength
    return records


def _parse_txt(rdata: bytes) -> dict[str, str]:
    values: dict[str, str] = {}
    index = 0
    while index < len(rdata):
        length = rdata[index]
        index += 1
        chunk = rdata[index : index + length].decode("utf-8", "replace")
        index += length
        key, _, value = chunk.partition("=")
        if key:
            values[key.lower()] = value
    return values


def parse_responses(packets: list[bytes]) -> list[Found]:
    """Build the printer list from raw mDNS response packets.

    Split out from the socket handling so the parsing - the part with the
    interesting edge cases - can be tested without a network.
    """
    services: dict[str, dict] = {}
    hosts: dict[str, str] = {}

    for data in packets:
        try:
            records = _read_records(data)
        except (ValueError, struct.error):
            logger.debug("Ignoring an unparsable mDNS packet", exc_info=True)
            continue
        for name, rtype, rdata, rdata_offset in records:
            try:
                if rtype == TYPE_SRV and len(rdata) >= 7:
                    _, _, port = struct.unpack(">HHH", rdata[:6])
                    target, _ = _read_name(data, rdata_offset + 6)
                    entry = services.setdefault(name, {})
                    entry["host"] = target.rstrip(".")
                    entry["port"] = port
                elif rtype == TYPE_TXT:
                    services.setdefault(name, {})["txt"] = _parse_txt(rdata)
                elif rtype == TYPE_A and len(rdata) == 4:
                    hosts[name.rstrip(".")] = socket.inet_ntoa(rdata)
            except (ValueError, struct.error):
                logger.debug("Ignoring an unparsable mDNS record", exc_info=True)

    found: list[Found] = []
    for service_name, entry in services.items():
        host = entry.get("host")
        if not host:
            continue
        txt = entry.get("txt", {})
        port = entry.get("port", 631)
        address = hosts.get(host, host)
        instance = service_name.split("._")[0].replace("\\032", " ")
        label = txt.get("ty") or txt.get("product", "").strip("()") or instance
        queue = (txt.get("rp") or "ipp/print").lstrip("/")
        server = address if port in (631, 0) else f"{address}:{port}"
        found.append(
            Found(
                name=label or instance,
                destination=queue,
                server=server,
                source="mdns",
                detail=f"ipp://{address}:{port}/{queue}",
            )
        )
    return found


def mdns_printers(timeout: float = 3.0) -> list[Found]:
    """One-shot DNS-SD query for the usual printer services.

    Returns an empty list rather than raising when multicast is unavailable:
    inside a bridged container that is the normal case, not an error worth
    failing the page over.
    """
    packets: list[bytes] = []
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    except OSError as exc:
        logger.info("No mDNS discovery: %s", exc)
        return []
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        sock.bind(("", 0))
        for service in MDNS_SERVICES:
            try:
                sock.sendto(_query(service), (MDNS_ADDRESS, MDNS_PORT))
            except OSError as exc:
                logger.info("Could not send the mDNS query for %s: %s", service, exc)

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, _sender = sock.recvfrom(MAX_RESPONSE_BYTES)
            except (TimeoutError, socket.timeout):
                break
            except OSError as exc:
                logger.info("mDNS discovery stopped: %s", exc)
                break
            packets.append(data)
    finally:
        sock.close()
    return parse_responses(packets)


# --- both -------------------------------------------------------------------


def discover(
    server: str = "",
    lpstat_binary: str = "lpstat",
    timeout: int = 10,
    mdns_timeout: float = 3.0,
    include_mdns: bool = True,
) -> tuple[list[Found], list[str]]:
    """Everything that could be found, plus the problems worth telling about.

    The queues of a CUPS server come first - they are the ones that can be
    used straight away - followed by devices that only announced themselves.
    A device already backing a queue is dropped from the second list.
    """
    found: list[Found] = []
    problems: list[str] = []

    try:
        found.extend(cups_queues(server, lpstat_binary=lpstat_binary, timeout=timeout))
    except DiscoveryError as exc:
        problems.append(f"CUPS ({server or 'lokal'}): {exc}")

    if include_mdns:
        known = {(entry.detail or "").lower() for entry in found}
        for entry in mdns_printers(timeout=mdns_timeout):
            if entry.detail.lower() in known:
                continue
            found.append(entry)
        if not any(entry.source == "mdns" for entry in found):
            problems.append(
                "Per mDNS wurde nichts gefunden. In einem Docker-Netz ist Multicast "
                "normalerweise nicht erreichbar - dann hilft nur der CUPS-Server oben "
                "oder das Geraet von Hand einzutragen."
            )

    return found, problems
MAIL2NAS_EOF

# --- mail2nas/runtime.py ---
cat > mail2nas/runtime.py <<'MAIL2NAS_EOF'
"""The objects the archiver and the web UI both work on.

Everything is configured in the web UI while the service runs, so something
has to hold the live state: the stores, the current settings snapshot, the
open archive connections, and what each worker is doing right now. That is
this module - a container plus the few operations that need coordinating
between the UI thread and the workers.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field, replace

from .archives import NoArchiveError, StorageSet
from .mapping import Mapping, RuleStore
from .options import Options, OptionsStore
from .printing import PrintService, Spooler

logger = logging.getLogger(__name__)


@dataclass
class WorkerStatus:
    """What the overview page shows for one mailbox (or the pickup folders)."""

    label: str
    state: str = "startet"  # startet | verbunden | wartet | Fehler | gestoppt
    detail: str = ""
    last_ok: float | None = None
    last_error: str = ""
    last_error_at: float | None = None
    processed: int = 0


@dataclass
class ArchiveStatus:
    ok: bool | None = None  # None = not checked yet
    detail: str = ""
    checked_at: float | None = None
    fingerprint: tuple = field(default_factory=tuple)


class StatusBoard:
    """Thread-safe notes from the workers, read by the web UI.

    Without it the only way to see whether a mailbox works would be the
    container log - and the whole point of configuring everything in the
    browser is not having to open a shell.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._workers: dict[str, WorkerStatus] = {}
        self.archive = ArchiveStatus()
        self.started_at = time.time()

    def worker(self, key: str, label: str) -> None:
        with self._lock:
            self._workers.setdefault(key, WorkerStatus(label=label))
            self._workers[key].label = label

    def set(self, key: str, state: str, detail: str = "") -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.state = state
            status.detail = detail
            if state in ("verbunden", "wartet"):
                status.last_ok = time.time()

    def error(self, key: str, message: str) -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.state = "Fehler"
            status.last_error = message
            status.last_error_at = time.time()

    def processed(self, key: str, count: int) -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.processed += count
            status.last_ok = time.time()

    def forget(self, key: str) -> None:
        with self._lock:
            self._workers.pop(key, None)

    def workers(self) -> dict[str, WorkerStatus]:
        with self._lock:
            return {key: replace(value) for key, value in self._workers.items()}


class Runtime:
    """Shared handles, plus the current settings snapshot."""

    def __init__(
        self,
        config,
        settings,
        accounts,
        store,
        rules: RuleStore,
        *,
        printers=None,
        printing: PrintService | None = None,
        addresses=None,
        archives=None,
        pickups=None,
    ):
        self.config = config
        self.settings = settings  # the key/value store
        self.options_store = OptionsStore(settings)
        self._options: Options | None = None
        self._options_lock = threading.Lock()

        self.accounts = accounts
        self.store = store
        self.rule_store = rules
        self.mapping = Mapping(rules, lambda: self.options.fallback_folder)
        self.printers = printers
        self.addresses = addresses
        self.archives = archives
        self.pickups = pickups
        self.storages = StorageSet(archives, None)
        if printing is None and printers is not None:
            printing = PrintService(
                printers, Spooler(lp_binary=config.lp_binary, options=lambda: self.options)
            )
        self.printing = printing
        self.status = StatusBoard()
        # Set by the web UI after a change the supervisor should act on right
        # away (an archive was added, the settings were saved) instead of at
        # its next regular pass.
        self.changed = threading.Event()
        # The running Supervisor, if any - the overview page asks it about
        # pickup folders with problems.
        self.supervisor = None

    # --- settings -------------------------------------------------------------

    @property
    def options(self) -> Options:
        """The current settings - one immutable snapshot, cheap to ask for."""
        with self._options_lock:
            if self._options is None:
                self._options = self.options_store.load()
            return self._options

    def set_options(self, options: Options) -> None:
        self.options_store.save(options)
        with self._options_lock:
            self._options = options
        self.changed.set()

    def invalidate_options(self) -> None:
        with self._options_lock:
            self._options = None

    @property
    def blocked_extensions(self) -> frozenset[str]:
        return self.options.blocked_extensions

    @property
    def pickup_min_age(self) -> int:
        return self.options.pickup_min_age

    # --- archives -------------------------------------------------------------

    @property
    def storage(self):
        """The default archive, or None while none is configured."""
        try:
            return self.storages.default()
        except NoArchiveError:
            return None

    def default_archive(self):
        return self.archives.default() if self.archives is not None else None
MAIL2NAS_EOF

# --- mail2nas/storage.py ---
cat > mail2nas/storage.py <<'MAIL2NAS_EOF'
"""Where archived attachments end up.

Two backends, same interface:

* `LocalStorage` writes into a directory. Something else (host fstab, a
  bind mount from the Proxmox host) has to have mounted the share there.
* `SmbStorage` speaks SMB directly from this process. Nothing is mounted
  anywhere, so it needs no mount privileges - which is what makes it work
  inside an unprivileged LXC, where the kernel refuses to mount CIFS at all.

The interface deliberately works on *path components* rather than on
strings: the target folders come from `mapping.yaml` on the share and are
untrusted, so they are validated once (`safe_relative_parts`) and then joined
by the backend onto its own root - a local path or a UNC path.
"""
from __future__ import annotations

import errno
import logging
import os
import secrets
import threading
from abc import ABC, abstractmethod
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .filenames import copy_atomic, safe_relative_parts, unique_path, write_atomic

logger = logging.getLogger(__name__)

TEMP_PREFIX = ".mail2nas-tmp-"
COPY_CHUNK = 1024 * 1024


@dataclass(frozen=True)
class StoredFile:
    """One file inside the archive, as `list_files` reports it."""

    parts: tuple[str, ...]  # relative to the root, including the file name
    size: int
    mtime: float

    @property
    def name(self) -> str:
        return self.parts[-1]

    @property
    def relative(self) -> str:
        return "/".join(self.parts)


class Storage(ABC):
    """Backend-independent view of the archive target."""

    @property
    @abstractmethod
    def description(self) -> str:
        """Human-readable location, for log lines and error messages."""

    @abstractmethod
    def check_writable(self) -> None:
        """Verify archiving can actually work, or raise SystemExit.

        Called once at startup. Without it, a share that is unreachable or
        read-only is indistinguishable from an empty one, and attachments
        would be written somewhere they silently disappear from.
        """

    @abstractmethod
    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        """Write `data` to `<root>/<parts>/<filename>`, creating directories.

        Never overwrites an existing file (a counter is appended instead) and
        never leaves a partially written file under the final name. Returns
        the full path that was written, for logging.
        """

    @abstractmethod
    def read_text(self, relative: str) -> str:
        """Read a UTF-8 text file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def read_bytes(self, relative: str) -> bytes:
        """Read a file relative to the root. Raises FileNotFoundError.

        Used when a document has to cross from one archive to another, where
        a streamed move is not possible because the two are different servers.
        """

    @abstractmethod
    def write_text(self, relative: str, text: str) -> None:
        """Overwrite a UTF-8 text file relative to the root, atomically.

        Unlike `save_unique` this replaces an existing file - it is used for
        the mapping file, which the web UI rewrites in place.
        """

    @abstractmethod
    def list_folders(self, max_depth: int = 2) -> list[str]:
        """Existing directories below the root, as relative POSIX paths.

        Feeds the folder picker in the web UI, so people assign keywords to
        folders that actually exist instead of typing a path by hand. Hidden
        directories are skipped.
        """

    @abstractmethod
    def create_folder(self, relative: str) -> None:
        """Create a directory below the root, including parents."""

    @abstractmethod
    def folder_exists(self, parts: Sequence[str]) -> bool:
        """True if `<root>/<parts>` is a directory.

        `list_files` cannot answer this: an empty folder and a mistyped one
        both look like "no files", and only one of them is worth telling
        somebody about.
        """

    @abstractmethod
    def list_files(self, parts: Sequence[str], max_depth: int = 5) -> list[StoredFile]:
        """Files below `<root>/<parts>`, recursively. Empty if it does not exist.

        Feeds the pickup folders: a scanner writes there, and mail2nas has to
        see what arrived, including in the per-user subfolders devices like to
        create. Hidden files are skipped.
        """

    @abstractmethod
    def move_unique(
        self, source_parts: Sequence[str], parts: Sequence[str], filename: str
    ) -> str:
        """Move `<root>/<source_parts>` to `<root>/<parts>/<filename>`.

        Copy-then-delete rather than a rename: the two can be on different
        shares once more than one archive is configured, and the original must
        only disappear once the copy is complete. Never overwrites (a counter
        is appended). Streamed, because a scan can be much larger than a mail
        attachment.
        """

    @abstractmethod
    def remove_file(self, relative: str) -> None:
        """Delete a file below the root. Missing is not an error."""

    @abstractmethod
    def modified_time(self, relative: str) -> float:
        """Modification time of a file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        """Full path as it would be written, without touching the target."""

    def close(self) -> None:
        """Release connections, if the backend holds any."""


class LocalStorage(Storage):
    """Archive into an already-mounted directory."""

    def __init__(self, root: str):
        self._root = Path(root)

    @property
    def description(self) -> str:
        return str(self._root)

    def check_writable(self) -> None:
        if not self._root.is_dir():
            raise SystemExit(
                f"STORAGE_ROOT {self._root} does not exist or is not a directory - "
                "is the share mounted? (With STORAGE_BACKEND=smb no mount is needed.)"
            )
        if not os.access(self._root, os.W_OK | os.X_OK):
            raise SystemExit(
                f"STORAGE_ROOT {self._root} is not writable by uid {os.getuid()} - "
                "check the mount options (uid/gid/file_mode) and the share permissions."
            )

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        directory = self._root.joinpath(*parts)
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, filename)
        write_atomic(out_path, data)
        return str(out_path)

    def read_text(self, relative: str) -> str:
        return self._resolve(relative).read_text(encoding="utf-8")

    def read_bytes(self, relative: str) -> bytes:
        return self._resolve(relative).read_bytes()

    def write_text(self, relative: str, text: str) -> None:
        path = self._resolve(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(path, text.encode("utf-8"))

    def list_folders(self, max_depth: int = 2) -> list[str]:
        found: list[str] = []

        def walk(directory: Path, prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(directory.iterdir(), key=lambda e: e.name.lower())
            except OSError:
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk(entry, f"{relative}/", depth + 1)

        walk(self._root, "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        self._root.joinpath(*safe_relative_parts(relative)).mkdir(parents=True, exist_ok=True)

    def folder_exists(self, parts: Sequence[str]) -> bool:
        return self._root.joinpath(*parts).is_dir()

    def list_files(self, parts: Sequence[str], max_depth: int = 5) -> list[StoredFile]:
        base = self._root.joinpath(*parts)
        found: list[StoredFile] = []

        def walk(directory: Path, prefix: tuple[str, ...], depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(directory.iterdir(), key=lambda e: e.name.lower())
            except OSError:
                return
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                try:
                    stat = entry.stat()
                except OSError:  # vanished between listing and stat
                    continue
                if entry.is_dir():
                    walk(entry, (*prefix, entry.name), depth + 1)
                elif entry.is_file():
                    found.append(
                        StoredFile((*prefix, entry.name), stat.st_size, stat.st_mtime)
                    )

        if base.is_dir():
            walk(base, tuple(parts), 1)
        return found

    def move_unique(
        self, source_parts: Sequence[str], parts: Sequence[str], filename: str
    ) -> str:
        source = self._root.joinpath(*source_parts)
        directory = self._root.joinpath(*parts)
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, filename)
        copy_atomic(source, out_path)
        try:
            source.unlink()
        except OSError:
            # The copy is only legitimate if the original goes away: a pickup
            # folder we cannot delete from would hand us the same scan again
            # on every single cycle.
            out_path.unlink(missing_ok=True)
            raise
        return str(out_path)

    def remove_file(self, relative: str) -> None:
        self._resolve(relative).unlink(missing_ok=True)

    def modified_time(self, relative: str) -> float:
        return self._resolve(relative).stat().st_mtime

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        path = self._root.joinpath(*parts)
        return str(path / filename) if filename else str(path)

    def _resolve(self, relative: str) -> Path:
        return self._root.joinpath(*safe_relative_parts(relative))


class SmbStorage(Storage):
    """Archive over SMB, without mounting the share anywhere.

    Every operation goes through `_with_reconnect`: a NAS that reboots, drops
    idle sessions or gets restarted mid-archive is normal in this deployment,
    and the archiver is a long-running process. A failed call therefore gets
    one retry on a fresh session before it is reported.
    """

    def __init__(
        self,
        host: str,
        share: str,
        user: str,
        password: str,
        domain: str | None = None,
        port: int = 445,
        root: str = "",
        encrypt: bool = True,
    ):
        self._host = host
        self._share = share
        self._user = user
        self._password = password
        self._domain = domain or None
        self._port = port
        self._encrypt = encrypt
        self._root_parts = safe_relative_parts(root) if root.strip() else ()
        self._connected = False
        # smbclient keys its connection pool by "server:port" and defaults to
        # 445 on every single call, so a non-default port has to be passed to
        # each operation - not just to register_session, which would otherwise
        # open a second (failing) connection on 445.
        self._kwargs = {"port": self._port}
        # Several account workers share one storage object. smbclient's own
        # connection pool is thread-safe, but the reconnect dance below is not:
        # two threads resetting the same session at once would fight over it.
        self._lock = threading.RLock()

    @property
    def description(self) -> str:
        # _unc() already prepends the root, so pass no extra components.
        return self._display_unc(())

    # --- session handling ---------------------------------------------------

    def _connect(self) -> None:
        if self._connected:
            return
        import smbclient

        # smbprotocol wants the domain in the username, not as a separate
        # argument. An empty domain must stay absent rather than become
        # "\\user", which some servers reject outright.
        username = f"{self._domain}\\{self._user}" if self._domain else self._user
        smbclient.register_session(
            self._host,
            username=username,
            password=self._password,
            port=self._port,
            encrypt=self._encrypt,
        )
        self._connected = True

    def _reset(self) -> None:
        self._connected = False
        try:
            import smbclient

            # Short timeout: the usual reason for resetting is that the server
            # stopped answering, and the default 60s wait for the logoff reply
            # would stall the retry that is the whole point of resetting.
            smbclient.delete_session(self._host, port=self._port, timeout=5)
        except Exception:  # noqa: BLE001 - tearing down a broken session must not raise
            logger.debug("Could not cleanly close the SMB session to %s", self._host, exc_info=True)

    def _with_reconnect(self, operation: str, func):
        """Run `func`, retrying once on a fresh session if it fails.

        A missing file is a legitimate answer (the mapping file may not exist
        yet), not a broken connection - those propagate without a reconnect,
        so callers can still catch FileNotFoundError.
        """
        with self._lock:
            return self._with_reconnect_locked(operation, func)

    def _with_reconnect_locked(self, operation: str, func):
        self._connect()
        try:
            return func()
        except FileNotFoundError:
            raise
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)
        except Exception as exc:  # noqa: BLE001 - smbprotocol raises non-OSError types too
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)

        self._reset()
        self._connect()
        try:
            return func()
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            raise

    # --- paths ---------------------------------------------------------------

    def _unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        segments = [*self._root_parts, *parts]
        if filename:
            segments.append(filename)
        return "\\".join([f"\\\\{self._host}\\{self._share}", *segments])

    def _display_unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        # Forward slashes in messages, matching how shares are written
        # everywhere else in this project (//nas/Belege/rechnungen).
        return self._unc(parts, filename).replace("\\", "/")

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        return self._display_unc(parts, filename)

    # --- operations ----------------------------------------------------------

    def check_writable(self) -> None:
        """Connect and write a probe file, so a broken setup fails at startup.

        Deliberately a single combined check rather than a reachability test
        followed by a write test: Samba refuses `stat` on a bare share root
        even for users who may write to it, so the write is the only probe
        that answers the question we actually care about.
        """
        probe = f"{TEMP_PREFIX}writetest-{os.getpid()}-{secrets.token_hex(4)}"
        try:
            self._with_reconnect("write test", lambda: self._write_probe(probe))
        except Exception as exc:  # noqa: BLE001 - turn any failure into an actionable message
            where = " (below SMB_ROOT)" if self._root_parts else ""
            raise SystemExit(
                f"Cannot archive to {self.description} over SMB: {exc}\n"
                "Check SMB_HOST/SMB_SHARE/SMB_USER/SMB_PASSWORD (and SMB_DOMAIN if your "
                f"server needs one), and that this user may write to the share{where}. "
                "If the server refuses encryption, set SMB_ENCRYPT=false."
            ) from exc

    def _write_probe(self, name: str) -> None:
        import smbclient

        self._ensure_dir(())
        path = self._unc((), name)
        with smbclient.open_file(path, mode="wb", **self._kwargs) as fh:
            fh.write(b"mail2nas write test")
        smbclient.remove(path, **self._kwargs)

    def _ensure_dir(self, parts: Sequence[str]) -> None:
        import smbclient

        if not parts and not self._root_parts:
            # The share root itself always exists - nothing to create.
            return
        smbclient.makedirs(self._unc(parts), exist_ok=True, **self._kwargs)

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        return self._with_reconnect("write", lambda: self._save_unique(parts, filename, data))

    def _save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        import smbclient
        import smbclient.path

        self._ensure_dir(parts)

        # Pick a free name. Single-writer assumption, same as the local
        # backend: mail2nas is one process per share path.
        target_name = self._free_name(parts, filename)

        # Write to a temporary name and rename into place, so an interrupted
        # transfer can never leave a truncated file under a name that looks
        # like a complete invoice.
        tmp_name = f"{TEMP_PREFIX}{secrets.token_hex(8)}"
        tmp_path = self._unc(parts, tmp_name)
        target_path = self._unc(parts, target_name)
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(data)
            smbclient.replace(tmp_path, target_path, **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

        return self._display_unc(parts, target_name)

    def read_text(self, relative: str) -> str:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("read", lambda: self._read_text(parts))

    def _read_text(self, parts: Sequence[str]) -> str:
        import smbclient

        with smbclient.open_file(
            self._unc(parts[:-1], parts[-1]), mode="r", encoding="utf-8", **self._kwargs
        ) as fh:
            return fh.read()

    def read_bytes(self, relative: str) -> bytes:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("read", lambda: self._read_bytes(parts))

    def _read_bytes(self, parts: Sequence[str]) -> bytes:
        import smbclient

        with smbclient.open_file(
            self._unc(parts[:-1], parts[-1]), mode="rb", **self._kwargs
        ) as fh:
            return fh.read()

    def write_text(self, relative: str, text: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("write", lambda: self._write_text(parts, text))

    def _write_text(self, parts: Sequence[str], text: str) -> None:
        import smbclient

        directory, name = tuple(parts[:-1]), parts[-1]
        self._ensure_dir(directory)
        tmp_path = self._unc(directory, f"{TEMP_PREFIX}{secrets.token_hex(8)}")
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(text.encode("utf-8"))
            smbclient.replace(tmp_path, self._unc(directory, name), **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

    def list_folders(self, max_depth: int = 2) -> list[str]:
        return self._with_reconnect("list", lambda: self._list_folders(max_depth))

    def _list_folders(self, max_depth: int) -> list[str]:
        import smbclient

        found: list[str] = []

        def walk(parts: tuple[str, ...], prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(
                    smbclient.scandir(self._unc(parts), **self._kwargs),
                    key=lambda e: e.name.lower(),
                )
            except Exception:  # noqa: BLE001 - an unreadable subfolder must not hide the rest
                logger.debug("Could not list %s", self._unc(parts), exc_info=True)
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk((*parts, entry.name), f"{relative}/", depth + 1)

        walk((), "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("mkdir", lambda: self._ensure_dir(parts))

    def folder_exists(self, parts: Sequence[str]) -> bool:
        base = tuple(parts)
        return self._with_reconnect("stat", lambda: self._folder_exists(base))

    def _folder_exists(self, parts: tuple[str, ...]) -> bool:
        import smbclient.path

        return bool(smbclient.path.isdir(self._unc(parts), **self._kwargs))

    def list_files(self, parts: Sequence[str], max_depth: int = 5) -> list[StoredFile]:
        base = tuple(parts)
        return self._with_reconnect("list files", lambda: self._list_files(base, max_depth))

    def _list_files(self, base: tuple[str, ...], max_depth: int) -> list[StoredFile]:
        import smbclient

        found: list[StoredFile] = []

        def walk(current: tuple[str, ...], depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(
                    smbclient.scandir(self._unc(current), **self._kwargs),
                    key=lambda e: e.name.lower(),
                )
            except Exception:  # noqa: BLE001 - a folder that is gone is simply empty
                logger.debug("Could not list %s", self._unc(current), exc_info=True)
                return
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                if entry.is_dir():
                    walk((*current, entry.name), depth + 1)
                    continue
                try:
                    stat = entry.stat()
                except Exception:  # noqa: BLE001 - vanished between listing and stat
                    continue
                found.append(
                    StoredFile((*current, entry.name), stat.st_size, stat.st_mtime)
                )

        walk(base, 1)
        return found

    def move_unique(
        self, source_parts: Sequence[str], parts: Sequence[str], filename: str
    ) -> str:
        source = tuple(source_parts)
        target = tuple(parts)
        return self._with_reconnect(
            "move", lambda: self._move_unique(source, target, filename)
        )

    def _move_unique(
        self, source_parts: tuple[str, ...], parts: tuple[str, ...], filename: str
    ) -> str:
        import smbclient
        import smbclient.path

        self._ensure_dir(parts)
        target_name = self._free_name(parts, filename)

        tmp_name = f"{TEMP_PREFIX}{secrets.token_hex(8)}"
        tmp_path = self._unc(parts, tmp_name)
        source_path = self._unc(source_parts[:-1], source_parts[-1])
        try:
            with smbclient.open_file(source_path, mode="rb", **self._kwargs) as src:
                with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as dst:
                    while True:
                        chunk = src.read(COPY_CHUNK)
                        if not chunk:
                            break
                        dst.write(chunk)
            smbclient.replace(tmp_path, self._unc(parts, target_name), **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed copy is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

        try:
            smbclient.remove(source_path, **self._kwargs)
        except Exception:
            # Without the delete the same file would be picked up again on the
            # next cycle, so the copy has to go rather than be duplicated.
            try:
                smbclient.remove(self._unc(parts, target_name), **self._kwargs)
            except Exception:  # noqa: BLE001
                logger.debug("Could not remove the copy either", exc_info=True)
            raise

        return self._display_unc(parts, target_name)

    def _free_name(self, parts: Sequence[str], filename: str) -> str:
        import smbclient.path

        target_name = filename
        stem, suffix = Path(filename).stem, Path(filename).suffix
        counter = 0
        while smbclient.path.exists(self._unc(parts, target_name), **self._kwargs):
            counter += 1
            target_name = f"{stem}_{counter}{suffix}"
        return target_name

    def remove_file(self, relative: str) -> None:
        parts = safe_relative_parts(relative)
        try:
            self._with_reconnect("remove", lambda: self._remove_file(parts))
        except FileNotFoundError:
            pass

    def _remove_file(self, parts) -> None:
        import smbclient

        smbclient.remove(self._unc(parts[:-1], parts[-1]), **self._kwargs)

    def modified_time(self, relative: str) -> float:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("stat", lambda: self._modified_time(parts))

    def _modified_time(self, parts: Sequence[str]) -> float:
        import smbclient

        return smbclient.stat(self._unc(parts[:-1], parts[-1]), **self._kwargs).st_mtime

    def close(self) -> None:
        self._reset()
MAIL2NAS_EOF

# --- mail2nas/mapping.py ---
cat > mail2nas/mapping.py <<'MAIL2NAS_EOF'
"""Keyword -> folder rules: storage, matching, and editing.

The rules live in the local database, next to the mailboxes and archives,
and are edited in the web UI. They used to be a `mapping.yaml` on the share;
`migrate.py` carries such a file over once, and the YAML format lives on as
the import/export format - a readable backup, and a way to move rules from one
installation to another.

Three things a rule expresses beyond keyword and target folder:

* **Order.** The first matching rule wins, and the order is explicit rather
  than derived, so "Rechnungskorrektur" can be placed above "RE" instead of
  relying on it happening to be the longer word.
* **Which mailbox a rule applies to**, once more than one IMAP account is
  configured.
* **Whether the match is printed**, and on which of the configured printers,
  and on which archive the folder is.

Export format (version 2)::

    version: 2
    rules:
      - keyword: Rechnungskorrektur
        folder: korrekturen
      - keyword: "RE*"
        folder: rechnungen
        account: "2"
        print: true
        printer: "1"

The old flat `keyword: folder` format is still read on import: longest
keyword first, which is exactly the priority that version applied implicitly.
"""
from __future__ import annotations

import logging
import re
import sqlite3
import threading
from collections.abc import Callable
from pathlib import Path
from dataclasses import dataclass, field, replace

import yaml

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

FILE_VERSION = 2
ALL_ACCOUNTS = "all"
MAX_KEYWORD_LENGTH = 100
# A pattern is a chain of ".*?" separated by literals, so matching cost grows
# with (wildcards x text length). Mail subjects and bodies are attacker-
# supplied, so both factors are bounded rather than trusted: without this a
# keyword like "a*a*a*a*a*..." plus a large body (body matching enabled) would tie
# up an account worker for a very long time.
MAX_WILDCARDS = 5
MAX_MATCH_LENGTH = 100_000


class MappingError(ValueError):
    """A rule the user tried to save is not usable."""


def _compile(keyword: str) -> re.Pattern[str] | None:
    """Build a matcher for a keyword containing `*` / `?`, or None for plain text.

    Wildcards stay *within* the substring search people already know: the
    pattern is not anchored, so "RE*2026" matches a subject that has "RE"
    somewhere followed later by "2026". `*Rechnung*` therefore means the same
    as plain `Rechnung`.
    """
    if "*" not in keyword and "?" not in keyword:
        return None
    if keyword.count("*") > MAX_WILDCARDS:
        # Loaded from a file that may have been edited by hand, so this has to
        # degrade rather than raise: treat it as plain text, which can only
        # match less, never more.
        logger.warning(
            "Keyword %r has more than %d wildcards - treating it as literal text",
            keyword,
            MAX_WILDCARDS,
        )
        return None
    pattern = "".join(
        ".*?" if char == "*" else "." if char == "?" else re.escape(char) for char in keyword
    )
    return re.compile(pattern, re.IGNORECASE | re.DOTALL)


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder assignment."""

    keyword: str
    folder: str
    account: str = ALL_ACCOUNTS  # ALL_ACCOUNTS or an account id as a string
    # Print the attachments this rule matches. The printer is optional: an
    # empty string means "whatever the mailbox is set to".
    print_attachments: bool = False
    printer: str = ""
    # Which archive the folder is on. Empty = the default archive, so a
    # mapping file written before there was more than one keeps working.
    archive: str = ""
    _matcher: re.Pattern[str] | None = field(default=None, compare=False, repr=False)

    @classmethod
    def create(
        cls,
        keyword: str,
        folder: str,
        account: str = ALL_ACCOUNTS,
        print_attachments: bool = False,
        printer: str = "",
        archive: str = "",
    ) -> "Rule":
        return cls(
            keyword,
            folder,
            account or ALL_ACCOUNTS,
            bool(print_attachments),
            str(printer or ""),
            str(archive or ""),
            _compile(keyword),
        )

    @property
    def has_wildcard(self) -> bool:
        return self._matcher is not None

    def applies_to(self, account_id: str | None) -> bool:
        if self.account == ALL_ACCOUNTS or account_id is None:
            return True
        return self.account == str(account_id)

    def matches(self, haystack_lower: str, haystack: str) -> bool:
        if self._matcher is not None:
            return self._matcher.search(haystack[:MAX_MATCH_LENGTH]) is not None
        return self.keyword.lower() in haystack_lower

    def as_dict(self) -> dict[str, object]:
        # Only what differs from the default is written, so a file that never
        # used printing stays exactly as short as it was.
        data: dict[str, object] = {"keyword": self.keyword, "folder": self.folder}
        if self.account != ALL_ACCOUNTS:
            data["account"] = self.account
        if self.print_attachments:
            data["print"] = True
        if self.printer:
            data["printer"] = self.printer
        if self.archive:
            data["archive"] = self.archive
        return data


def _as_bool(value) -> bool:
    """Read a flag from a file someone may have edited by hand.

    YAML already turns `true`/`yes` into booleans, but `print: "ja"` is the
    kind of thing that gets typed - and silently treating it as false would
    mean paper that never comes out with nothing to explain why.
    """
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on", "ja")


def parse_rules(raw) -> list[Rule]:
    """Turn parsed YAML into rules, accepting both file formats."""
    if not raw:
        return []

    if isinstance(raw, dict) and "rules" in raw:
        entries = raw.get("rules") or []
        if not isinstance(entries, list):
            raise MappingError("'rules' muss eine Liste von Zuordnungen sein.")
        rules = []
        for entry in entries:
            if not isinstance(entry, dict) or "keyword" not in entry or "folder" not in entry:
                raise MappingError("Jede Zuordnung braucht 'keyword' und 'folder'.")
            rules.append(
                Rule.create(
                    str(entry["keyword"]),
                    str(entry["folder"]),
                    str(entry.get("account", ALL_ACCOUNTS)),
                    _as_bool(entry.get("print", False)),
                    str(entry.get("printer", "") or ""),
                    str(entry.get("archive", "") or ""),
                )
            )
        return rules

    if isinstance(raw, dict):
        # Legacy flat format. Longest keyword first reproduces the priority the
        # old matcher applied implicitly, so migrating cannot change behaviour.
        pairs = sorted(raw.items(), key=lambda kv: len(str(kv[0])), reverse=True)
        return [Rule.create(str(keyword), str(folder)) for keyword, folder in pairs]

    raise MappingError("Die Datei enthaelt keine Stichwort/Ordner-Zuordnungen.")


def dump_rules(rules: list[Rule]) -> str:
    """Render rules as YAML, preserving their order."""
    document = {"version": FILE_VERSION, "rules": [rule.as_dict() for rule in rules]}
    return yaml.safe_dump(document, allow_unicode=True, default_flow_style=False, sort_keys=False)


def rules_from_yaml(text: str) -> list[Rule]:
    """Parse an exported (or old on-share) rule file."""
    try:
        raw = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise MappingError(f"Die Datei ist kein gueltiges YAML: {exc}") from None
    return parse_rules(raw)


class RuleStore:
    """The rule list in the database, in priority order.

    Saved as a whole: the UI always edits the complete, ordered list (moving
    one rule changes the position of two), and replacing it in one
    transaction means a reader never sees a list that is half old, half new.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS mapping_rules ("
                "position INTEGER PRIMARY KEY, "
                "keyword TEXT NOT NULL, "
                "folder TEXT NOT NULL, "
                "account TEXT NOT NULL DEFAULT 'all', "
                "print INTEGER NOT NULL DEFAULT 0, "
                "printer TEXT NOT NULL DEFAULT '', "
                "archive TEXT NOT NULL DEFAULT '')"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    def load(self) -> list[Rule]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT keyword, folder, account, print, printer, archive "
                "FROM mapping_rules ORDER BY position"
            ).fetchall()
        return [
            Rule.create(keyword, folder, account, bool(printing), printer, archive)
            for keyword, folder, account, printing, printer, archive in rows
        ]

    def save(self, rules: list[Rule]) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM mapping_rules")
            conn.executemany(
                "INSERT INTO mapping_rules (position, keyword, folder, account, print, "
                "printer, archive) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [
                    (
                        position,
                        rule.keyword,
                        rule.folder,
                        rule.account or ALL_ACCOUNTS,
                        1 if rule.print_attachments else 0,
                        rule.printer,
                        rule.archive,
                    )
                    for position, rule in enumerate(rules)
                ],
            )

    def count(self) -> int:
        with self._connect() as conn:
            return int(conn.execute("SELECT COUNT(*) FROM mapping_rules").fetchone()[0])


class Mapping:
    """The rule list as the archiver sees it.

    Shared by every account worker and the pickup runner. `reload()` is called
    at the start of each cycle and re-reads the table - a handful of rows from
    a local file, cheaper than any cleverness about noticing changes.
    """

    def __init__(self, store: RuleStore, fallback_folder: str | Callable[[], str] = "unsorted"):
        self._store = store
        self._fallback_folder = fallback_folder
        self._lock = threading.Lock()
        self._rules: list[Rule] = []
        self.reload()

    @property
    def store(self) -> RuleStore:
        return self._store

    @property
    def rules(self) -> list[Rule]:
        with self._lock:
            return list(self._rules)

    def reload(self) -> None:
        try:
            rules = self._store.load()
        except Exception as exc:  # noqa: BLE001 - keep the last good rules
            logger.error("Could not read the mapping rules (%s) - keeping the previous %d",
                         exc, len(self._rules))
            return
        with self._lock:
            self._rules = rules

    def save(self, rules: list[Rule]) -> None:
        self._store.save(rules)
        with self._lock:
            self._rules = list(rules)

    def match(self, *texts: str, account_id: str | None = None) -> Rule | None:
        """Return the first rule that matches, or None.

        The whole rule rather than just its folder: the caller also needs to
        know whether the match should be printed, and on which printer.
        """
        haystack = " ".join(t for t in texts if t)
        haystack_lower = haystack.lower()
        with self._lock:
            rules = self._rules
        for rule in rules:
            if rule.applies_to(account_id) and rule.matches(haystack_lower, haystack):
                return rule
        return None

    def fallback_folder(self) -> str:
        value = self._fallback_folder
        return value() if callable(value) else value

    def resolve(self, *texts: str, account_id: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword) for the first matching rule."""
        rule = self.match(*texts, account_id=account_id)
        return (rule.folder, rule.keyword) if rule else (self.fallback_folder(), None)


# --- editing helpers (used by the web UI) ------------------------------------


def validate_keyword(keyword: str, existing: list[Rule], replacing: int | None = None) -> str:
    """Check a keyword the user typed, returning the cleaned version."""
    keyword = keyword.strip()
    if not keyword:
        raise MappingError("Bitte ein Stichwort angeben.")
    if len(keyword) > MAX_KEYWORD_LENGTH:
        raise MappingError(f"Das Stichwort darf hoechstens {MAX_KEYWORD_LENGTH} Zeichen lang sein.")
    if "\n" in keyword or "\r" in keyword:
        raise MappingError("Das Stichwort darf keine Zeilenumbrueche enthalten.")
    if keyword.strip("*? ") == "":
        raise MappingError("Ein Stichwort aus lauter Platzhaltern wuerde auf alles passen.")
    if keyword.count("*") > MAX_WILDCARDS:
        raise MappingError(f"Hoechstens {MAX_WILDCARDS} Platzhalter (*) pro Stichwort.")
    # Matching is case-insensitive, so two rules with the same keyword for the
    # same account would be indistinguishable - the second could never win.
    lowered = keyword.lower()
    for index, rule in enumerate(existing):
        if index == replacing:
            continue
        if rule.keyword.lower() == lowered:
            raise MappingError(f"Das Stichwort {rule.keyword!r} gibt es schon.")
    return keyword


def validate_folder(folder: str) -> str:
    """Check a target folder, returning the cleaned relative path."""
    folder = folder.strip().replace("\\", "/")
    if not folder:
        raise MappingError("Bitte einen Zielordner auswaehlen oder anlegen.")
    try:
        parts = safe_relative_parts(folder)
    except ValueError as exc:
        raise MappingError(f"Ungueltiger Zielordner: {exc}") from None
    return "/".join(parts)


def move_rule(rules: list[Rule], index: int, offset: int) -> list[Rule]:
    """Return the rules with one entry moved up or down."""
    if not 0 <= index < len(rules):
        raise MappingError("Diese Zuordnung gibt es nicht mehr.")
    target = index + offset
    if not 0 <= target < len(rules):
        return rules
    reordered = list(rules)
    reordered.insert(target, reordered.pop(index))
    return reordered


def set_account(rule: Rule, account: str) -> Rule:
    return replace(rule, account=account or ALL_ACCOUNTS)


def set_archive(rule: Rule, archive: str) -> Rule:
    """Move a rule's target folder to another archive ("" = the default one)."""
    return replace(rule, archive=str(archive or ""))


def set_printing(rule: Rule, print_attachments: bool, printer: str) -> Rule:
    """Change a rule's print settings, dropping the printer when off."""
    print_attachments = bool(print_attachments)
    return replace(
        rule,
        print_attachments=print_attachments,
        printer=str(printer or "") if print_attachments else "",
    )
MAIL2NAS_EOF

# --- mail2nas/filenames.py ---
cat > mail2nas/filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import re
import shutil
import tempfile
import unicodedata
from pathlib import Path

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")

# Characters that are path separators, reserved on Windows/SMB, or control
# characters. Folder names keep spaces and non-ASCII letters (people do name
# folders "Rechnungen 2026"), so this is deliberately more permissive than
# the attachment-filename sanitizer.
_UNSAFE_SEGMENT = re.compile(r'[\x00-\x1f\x7f<>:"|?*\\/]+')


def sanitize_filename(name: str) -> str:
    """Strip characters that are awkward on SMB shares / cross-platform filesystems."""
    name = unicodedata.normalize("NFKD", name)
    name = _UNSAFE.sub("_", name).strip("._")
    return name or "attachment"


def extension_of(filename: str) -> str:
    """Lower-cased extension without the dot, or "" if there is none."""
    if "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].strip().lower()


def sanitize_path_segment(segment: str) -> str:
    """Sanitize a single folder-name component (never a path)."""
    segment = unicodedata.normalize("NFKC", segment)
    segment = _UNSAFE_SEGMENT.sub("_", segment)
    # Trailing dots/spaces are silently dropped by Windows/SMB, which would
    # make the on-disk name differ from what was configured.
    return segment.strip().rstrip(". ").strip()


def safe_relative_parts(relative: str) -> tuple[str, ...]:
    """Split `relative` into validated, sanitized path components.

    The target folders come from `mapping.yaml`, which lives on the archive
    share itself - so whoever can edit that file could otherwise redirect
    attachments anywhere the process can write, via `../..` or an absolute
    path.

    Absolute paths and `..` components are refused rather than reinterpreted,
    and every remaining component is sanitized. Nested targets such as
    "rechnungen/2026" stay supported. Raises ValueError if nothing usable is
    left, so the caller can fall back to a known-good folder.

    Returning components rather than a joined path keeps this usable for both
    storage backends: the local one joins them onto a filesystem root, the SMB
    one onto a UNC path.
    """
    raw = str(relative).replace("\\", "/")

    if raw.strip().startswith("/"):
        # Confining "/etc/cron.d" to "<root>/etc/cron.d" would be safe but
        # produces a surprising deep tree on the share. An absolute target is
        # always a misconfiguration, so say so and let the caller fall back.
        raise ValueError(f"Target folder must be relative to the storage root: {relative!r}")

    parts: list[str] = []
    for candidate in raw.split("/"):
        candidate = candidate.strip()
        if candidate in ("", "."):
            continue
        if candidate == "..":
            raise ValueError(f"Refusing parent-directory component in target folder: {relative!r}")
        cleaned = sanitize_path_segment(candidate)
        if not cleaned or cleaned == "..":
            raise ValueError(f"Target folder component is empty after sanitizing: {relative!r}")
        parts.append(cleaned)

    if not parts:
        raise ValueError(f"Target folder is empty: {relative!r}")

    return tuple(parts)


def safe_join(root: str | Path, relative: str) -> Path:
    """Join `relative` onto `root`, guaranteeing the result stays under `root`.

    See `safe_relative_parts` for what is accepted. (Note `Path("/mnt/nas") /
    "/etc"` yields `/etc`: an absolute right operand discards the root
    entirely - hence the validation rather than a plain join.)
    """
    root_path = Path(root)
    result = root_path.joinpath(*safe_relative_parts(relative))

    # Belt and braces: the component filtering above already makes escaping
    # impossible, but verify containment lexically so any future change to the
    # parsing cannot silently reopen the hole.
    root_abs = os.path.abspath(root_path)
    result_abs = os.path.abspath(result)
    if result_abs != root_abs and not result_abs.startswith(root_abs.rstrip(os.sep) + os.sep):
        raise ValueError(f"Target folder escapes the storage root: {relative!r}")

    return result


def unique_path(directory: str | Path, filename: str) -> Path:
    """Return a path for `filename` inside `directory`, avoiding overwrites."""
    directory = Path(directory)
    candidate = directory / filename
    if not candidate.exists():
        return candidate

    stem, suffix = Path(filename).stem, Path(filename).suffix
    counter = 1
    while True:
        candidate = directory / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def copy_atomic(source: str | Path, path: str | Path) -> None:
    """Copy `source` to `path` via a temporary file plus rename.

    Same reasoning as write_atomic, but streamed: a file picked up from a
    scanner folder is already on disk and can be far larger than a mail
    attachment, so there is no reason to pull it through memory.
    """
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mail2nas-tmp-")
    try:
        with open(source, "rb") as src, os.fdopen(fd, "wb") as dst:
            shutil.copyfileobj(src, dst)
            dst.flush()
            os.fsync(dst.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def write_atomic(path: str | Path, data: bytes) -> None:
    """Write `data` to `path` via a temporary file plus rename.

    A direct write that is interrupted (container restart, SMB share dropping
    mid-transfer) would leave a truncated file behind that still looks like a
    complete invoice. Renaming into place means the final name only ever
    appears once the bytes are fully written.
    """
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mail2nas-tmp-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
MAIL2NAS_EOF

# --- mail2nas/state.py ---
cat > mail2nas/state.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import sqlite3
import threading
from pathlib import Path


class ProcessedStore:
    """Tracks Message-IDs that have already been archived.

    IMAP's \\Seen flag alone is not a safe idempotency marker (it can be
    reset by another client, or the folder can be re-synced), so we keep a
    small local record of what has actually been written to the share.

    One connection shared by every account worker, guarded by a lock:
    sqlite3 connections are not safe to use from several threads at once, and
    the writes here are short enough that serialising them costs nothing.
    """

    def __init__(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, timeout=10, check_same_thread=False)
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS processed_messages ("
                "message_id TEXT PRIMARY KEY, "
                "processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )
            self._conn.commit()

    def is_processed(self, message_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "SELECT 1 FROM processed_messages WHERE message_id = ?", (message_id,)
            )
            return cur.fetchone() is not None

    def mark_processed(self, message_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO processed_messages (message_id) VALUES (?)", (message_id,)
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()


class SettingsStore:
    """Small key/value store for things the web UI has to remember.

    Lives in the same SQLite file as the processed-message table, so there is
    still exactly one piece of local state to back up or throw away.

    Unlike `ProcessedStore` this opens a short-lived connection per call: the
    web UI answers requests on a thread pool, and one sqlite3 connection must
    not be shared across threads. The settings are read/written rarely enough
    that the extra connect costs nothing.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS settings ("
                "key TEXT PRIMARY KEY, "
                "value TEXT NOT NULL, "
                "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    def get(self, key: str) -> str | None:
        with self._connect() as conn:
            row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set(self, key: str, value: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO settings (key, value, updated_at) "
                "VALUES (?, ?, CURRENT_TIMESTAMP) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value, "
                "updated_at = CURRENT_TIMESTAMP",
                (key, value),
            )
MAIL2NAS_EOF

# --- mail2nas/archiver.py ---
cat > mail2nas/archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import email
import logging
from dataclasses import dataclass
from email.header import decode_header, make_header
from email.message import Message
from email.utils import getaddresses, parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .accounts import Account
from .addresses import AddressRule, AddressStore
from .archives import StorageSet
from .filenames import extension_of, safe_relative_parts, sanitize_filename
from .mapping import Mapping, Rule
from .options import Options
from .printers import Printer
from .printing import PrintService, job_title
from .state import ProcessedStore

logger = logging.getLogger(__name__)

# Where the address a mail was actually delivered to can be found. The
# envelope headers come first: an alias like "drucker@firma.de" is usually
# delivered into a shared mailbox, and then only the delivery headers still
# name the alias - To: may say something else entirely (or nothing, for Bcc).
RECIPIENT_HEADERS = (
    "Delivered-To",
    "X-Original-To",
    "Envelope-To",
    "X-Envelope-To",
    "X-RcptTo",
    "To",
    "Cc",
    "Resent-To",
    "X-Forwarded-To",
)
# A mail may legitimately carry a few dozen recipients; thousands are either a
# mistake or an attempt to make matching expensive.
MAX_RECIPIENTS = 50
# Seconds a single IMAP command may take. Without a timeout a server that
# stops answering mid-session blocks the worker forever - no error, no retry.
IMAP_TIMEOUT = 60


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def recipients_of(msg: Message) -> list[str]:
    """Every address this message was addressed or delivered to, lowercased."""
    found: list[str] = []
    seen: set[str] = set()
    for header in RECIPIENT_HEADERS:
        for raw in msg.get_all(header, []):
            for _, address in getaddresses([_decode(raw)]):
                address = address.strip().lower()
                if not address or address in seen:
                    continue
                seen.add(address)
                found.append(address)
                if len(found) >= MAX_RECIPIENTS:
                    logger.warning(
                        "Message has more than %d recipients - only those are matched",
                        MAX_RECIPIENTS,
                    )
                    return found
    return found


def _message_id(msg: Message, uid: int, account_key: str) -> str:
    """Idempotency key. Scoped per account: the same message delivered to two
    watched mailboxes is two things to archive, not one."""
    return f"{account_key}:" + (msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>")


@dataclass(frozen=True)
class AttachmentPlan:
    """What is to happen with one attachment, decided before anything happens.

    Filing and printing are two independent answers to the same question, and
    both depend on the same rule match - so they are worked out together and
    then carried out, rather than being re-derived at each step.
    """

    folder: str
    keyword: str | None
    quarantined: bool
    archive: bool
    printer: Printer | None
    address: AddressRule | None = None
    # Which archive the folder is on; "" = the default one. Not to be confused
    # with `archive` above, which says *whether* to file at all.
    archive_key: str = ""


class Archiver:
    def __init__(
        self,
        options,
        mapping: Mapping,
        store: ProcessedStore,
        storages,
        account: Account,
        printing: PrintService | None = None,
        addresses: AddressStore | None = None,
    ):
        # `options` is an Options snapshot or a callable returning the current
        # one. The callable is what the service uses: the settings page takes
        # effect on the next message, without restarting the worker.
        self._options = options
        self.mapping = mapping
        self.store = store
        # A StorageSet (one storage per archive), or a single Storage for an
        # installation - or a test - with exactly one place to file into.
        self.storages = storages
        self.account = account
        self.printing = printing
        # Optional, like `printing`: an installation without address rules
        # behaves exactly as before.
        self.addresses = addresses

    @property
    def options(self) -> Options:
        return self._options() if callable(self._options) else self._options

    @property
    def blocked_extensions(self) -> frozenset[str]:
        return self.options.blocked_extensions

    def storage_for(self, archive_key: str):
        """The archive a plan points at, or the only one there is."""
        if isinstance(self.storages, StorageSet):
            return self.storages.get(archive_key)
        return self.storages

    def connect(self) -> IMAPClient:
        client = IMAPClient(
            self.account.host, port=self.account.port, ssl=self.account.ssl, timeout=IMAP_TIMEOUT
        )
        client.login(self.account.user, self.account.password)
        client.select_folder(self.account.folder)
        return client

    def _match(self, *texts: str) -> Rule | None:
        # Rules can be limited to a single mailbox, so the account has to be
        # part of every lookup.
        return self.mapping.match(*texts, account_id=self.account.key)

    def run_once(self, client: IMAPClient) -> int:
        """Process all currently unseen messages. Returns the number processed."""
        self.mapping.reload()
        uids = client.search(["UNSEEN"])
        if not uids:
            return 0

        processed = 0
        for uid in uids:
            try:
                if self._process_message(client, uid):
                    processed += 1
            except Exception:
                logger.exception("Failed to process message UID %s, leaving it for retry", uid)
        return processed

    def _process_message(self, client: IMAPClient, uid: int) -> bool:
        # Check the message size *before* pulling the full body into memory -
        # a hostile/broken sender could otherwise use an oversized message to
        # exhaust memory/disk on every poll cycle.
        size_reply = client.fetch([uid], ["RFC822.SIZE"])
        message_size = size_reply.get(uid, {}).get(b"RFC822.SIZE", 0)
        max_message_bytes = self.options.max_message_size_mb * 1024 * 1024
        if message_size and message_size > max_message_bytes:
            logger.warning(
                "UID %s is %.1f MB, exceeds MAX_MESSAGE_SIZE_MB=%d - skipping attachment "
                "extraction and flagging for manual review",
                uid,
                message_size / (1024 * 1024),
                self.options.max_message_size_mb,
            )
            if not self.options.dry_run:
                client.add_flags([uid], [b"\\Seen"])
                if self.account.oversized_folder:
                    client.move([uid], self.account.oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid, self.account.key)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
            return False

        subject = _decode(msg.get("Subject"))
        _, sender_addr = parseaddr(_decode(msg.get("From")))
        body = self._extract_body(msg) if self.options.match_body else ""
        mail_rule = self._match(subject, body)
        address_rule = self._address_rule(msg, sender_addr)
        if address_rule is not None:
            logger.info(
                "UID %s '%s' is addressed to %s (%s)",
                uid,
                subject,
                address_rule.recipient or address_rule.sender,
                address_rule.name,
            )

        attachments = list(self._iter_attachments(msg))
        if len(attachments) > self.options.max_attachments_per_message:
            logger.warning(
                "UID %s '%s' has %d attachments, only processing the first %d "
                "(MAX_ATTACHMENTS_PER_MESSAGE)",
                uid,
                subject,
                len(attachments),
                self.options.max_attachments_per_message,
            )
            attachments = attachments[: self.options.max_attachments_per_message]

        saved: list[str] = []
        if not attachments:
            logger.info("UID %s '%s' has no attachments, nothing to save", uid, subject)
        else:
            date_prefix = self._date_prefix(msg)
            max_attachment_bytes = self.options.max_attachment_size_mb * 1024 * 1024
            for filename, payload in attachments:
                if len(payload) > max_attachment_bytes:
                    logger.warning(
                        "UID %s '%s': attachment '%s' is %.1f MB, exceeds "
                        "MAX_ATTACHMENT_SIZE_MB=%d - skipping this attachment",
                        uid,
                        subject,
                        filename,
                        len(payload) / (1024 * 1024),
                        self.options.max_attachment_size_mb,
                    )
                    continue

                plan = self._plan_attachment(filename, mail_rule, address_rule)
                out_name = self._build_filename(date_prefix, sender_addr, filename)

                if plan.archive:
                    self._file(plan, out_name, payload, uid, subject, filename, saved)

                # Printing comes after filing, deliberately: the share is the
                # archive and paper is the copy, so a printer that is offline
                # or out of paper must never be the reason an attachment was
                # not stored.
                printed = False
                if plan.printer is not None:
                    printed = self.printing.send(
                        plan.printer, payload, out_name, job_title(subject, filename)
                    )

                if not plan.archive and not printed:
                    # "Print only" and yet nothing came out - no printer, a
                    # format it cannot print, CUPS down. The mail is marked as
                    # read in a moment, so this is the last chance to keep the
                    # attachment: file it after all rather than lose it.
                    logger.warning(
                        "UID %s '%s': attachment '%s' was meant to be printed only, but "
                        "nothing was printed - filing it instead so it is not lost",
                        uid,
                        subject,
                        filename,
                    )
                    self._file(plan, out_name, payload, uid, subject, filename, saved)
                elif not plan.archive:
                    logger.info(
                        "UID %s '%s': attachment '%s' printed, not archived (%s)",
                        uid,
                        subject,
                        filename,
                        f"address rule {plan.address.name!r}"
                        if plan.address is not None
                        else "mailbox set to print only",
                    )

        if not self.options.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.account.processed_folder:
                client.move([uid], self.account.processed_folder)
        return True

    def _file(self, plan, out_name, payload, uid, subject, filename, saved) -> None:
        target_parts = self._target_parts(plan.folder)
        storage = self.storage_for(plan.archive_key)
        if self.options.dry_run:
            logger.info("[dry-run] would save %s -> %s", out_name, storage.display(target_parts))
            return
        out_path = storage.save_unique(target_parts, out_name, payload)
        saved.append(out_path)
        logger.info(
            "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
            uid,
            subject,
            filename,
            plan.keyword or "<fallback>",
            " [QUARANTAENE: gesperrte Dateiendung]" if plan.quarantined else "",
            out_path,
        )

    def _target_parts(self, folder_name: str) -> tuple[str, ...]:
        """Map a configured folder name onto path components inside the archive root.

        Folder names come from rules and address entries - and a rule file
        imported from somewhere else is not necessarily trustworthy; anything that would escape the archive root is rejected and
        replaced with the fallback folder rather than being written outside.
        """
        for candidate, note in ((folder_name, None), (self.options.fallback_folder, "fallback"), ("unsorted", "built-in")):
            try:
                target = safe_relative_parts(candidate)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the archive root", candidate, exc
                )
                continue
            if note and candidate != folder_name:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder_name)
            return target
        raise ValueError("No usable target folder inside the archive root")

    def _address_rule(self, msg: Message, sender_addr: str) -> AddressRule | None:
        """The configured address this mail was sent to, if any."""
        if self.addresses is None:
            return None
        try:
            return self.addresses.match(recipients_of(msg), sender_addr)
        except Exception:
            # Routing is a convenience; a broken lookup must not stop the mail
            # from being archived the ordinary way.
            logger.exception("Could not match the delivery address - continuing without it")
            return None

    def _plan_attachment(
        self, filename: str, mail_rule: Rule | None, address_rule: AddressRule | None = None
    ) -> AttachmentPlan:
        """Decide where a single attachment is filed, and whether it is printed.

        The attachment's own filename is checked against the mapping first,
        so multiple differently-named attachments on the same mail can land
        in different folders. Falls back to the mail-level (subject/body)
        match when the filename itself gives no hint. Attachments with a
        blocked extension are always quarantined, regardless of any keyword
        match, so a malicious/executable attachment can never be renamed
        into a trusted-looking business folder just by naming it "Rechnung.exe".

        An address rule outranks both. Somebody who sends a document to
        `drucker-buero@firma.de` has said what should happen with it more
        clearly than any keyword can; the keywords then only still decide the
        folder, and only if the address rule names none.
        """
        rule = self._match(filename) or mail_rule

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(filename), extension_of(sanitize_filename(_decode(filename)))}
        quarantined = bool(extensions & self.blocked_extensions)

        return AttachmentPlan(
            folder=self.options.quarantine_folder if quarantined else self._folder_of(rule, address_rule),
            keyword=rule.keyword if rule else None,
            quarantined=quarantined,
            archive_key=self._archive_of(rule, address_rule),
            # "Print only" still files anything quarantined: it cannot be
            # printed either, and dropping it without a trace would hide
            # exactly the attachment somebody may need to look at.
            archive=self._archives(address_rule) or quarantined,
            printer=self._printer_for(rule, quarantined, address_rule),
            address=address_rule,
        )

    def _archives(self, address_rule: AddressRule | None) -> bool:
        if address_rule is not None:
            return address_rule.archive_attachments
        return self.account.archive_attachments

    def _folder_of(self, rule: Rule | None, address_rule: AddressRule | None = None) -> str:
        if address_rule is not None and address_rule.folder:
            return address_rule.folder
        return rule.folder if rule else self.options.fallback_folder

    def _archive_of(self, rule: Rule | None, address_rule: AddressRule | None = None) -> str:
        """Which archive the folder lives on.

        An address rule that names one wins - it is the more specific
        statement, even when the folder itself comes from a keyword rule
        ("file it where it usually goes, but on that NAS").
        """
        if address_rule is not None and address_rule.archive:
            return address_rule.archive
        return rule.archive if rule else ""

    def _printer_for(
        self, rule: Rule | None, quarantined: bool, address_rule: AddressRule | None = None
    ) -> Printer | None:
        """Which printer this attachment goes to, if any.

        Printing is requested by the address it was sent to ("everything for
        drucker-buero@ goes on the office printer"), by the mailbox ("print
        everything that arrives here") or by the matched rule ("print
        invoices"). The printer is then the most specific one configured:
        address before rule before mailbox.

        A matching address rule also has the last word on *whether* to print.
        Its whole purpose is to say what happens to mail sent there, so an
        address set to "only file" is not overruled by a keyword rule.
        """
        if self.printing is None or not self.options.printing_enabled:
            return None
        if quarantined:
            # A blocked attachment is a suspected executable. It is neither
            # printable nor something to hand to a printer driver.
            return None

        by_rule = rule is not None and rule.print_attachments
        if address_rule is not None:
            if not address_rule.print_attachments:
                return None
            keys = (address_rule.printer, rule.printer if by_rule else "", self.account.printer)
            wanted_by = f"address {address_rule.name!r}"
        else:
            if not (self.account.print_attachments or by_rule):
                return None
            keys = (rule.printer if by_rule else "", self.account.printer)
            wanted_by = f"rule {rule.keyword!r}" if by_rule else f"mailbox {self.account.name!r}"

        printer = self.printing.printer_for(*keys)
        if printer is None:
            logger.warning(
                "Printing is enabled for %s but no usable printer is configured - "
                "nothing was printed",
                wanted_by,
            )
        return printer

    @staticmethod
    def _date_prefix(msg: Message) -> str:
        date_header = msg.get("Date")
        if date_header:
            try:
                return parsedate_to_datetime(date_header).strftime("%Y-%m-%d")
            except (TypeError, ValueError):
                pass
        return "unknown-date"

    def _build_filename(self, date_prefix: str, sender_addr: str, filename: str) -> str:
        filename = sanitize_filename(_decode(filename))
        mode = self.options.filename_prefix
        if mode == "none":
            return filename
        if mode == "date":
            return f"{date_prefix}_{filename}"
        sender = sanitize_filename(sender_addr or "unknown")
        if mode == "sender":
            return f"{sender}_{filename}"
        return f"{date_prefix}_{sender}_{filename}"

    @staticmethod
    def _iter_attachments(msg: Message):
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            disposition = part.get_content_disposition()
            filename = part.get_filename()
            if disposition != "attachment" and not filename:
                continue
            payload = part.get_payload(decode=True)
            if payload is None:
                continue
            yield filename or "attachment", payload

    @staticmethod
    def _extract_body(msg: Message) -> str:
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain" and not part.get_filename():
                    try:
                        return part.get_payload(decode=True).decode(
                            part.get_content_charset() or "utf-8", errors="replace"
                        )
                    except Exception:
                        continue
            return ""
        try:
            return msg.get_payload(decode=True).decode(msg.get_content_charset() or "utf-8", errors="replace")
        except Exception:
            return ""
MAIL2NAS_EOF

# --- mail2nas/scanning.py ---
cat > mail2nas/scanning.py <<'MAIL2NAS_EOF'
"""Emptying the pickup folders: what a device wrote, filed like a mail.

One pass over every configured folder, run from the supervisor. The rules,
the quarantine and the naming are the same ones the IMAP path uses - a scan
that arrives by mail and the same scan dropped into a folder must not end up
in different places.

Two properties this has to keep:

* **A file is only touched once it is finished.** A scan being transferred
  over SMB is a file that exists, grows, and is worthless until it stops -
  so nothing is picked up before it has been untouched for a while.
* **The original goes away.** The pickup folder is an outbox, not an archive;
  a copy left behind would be imported again on the next cycle.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime

from .filenames import extension_of, sanitize_filename
from .pickups import MAX_DEPTH, Pickup, PickupStore
from .printing import job_title

logger = logging.getLogger(__name__)

# Names that are never a finished document: dotfiles (the archive's own
# temporary files start with one) and the suffixes devices and SMB clients use
# while a file is still being written.
IGNORED_SUFFIXES = (".tmp", ".part", ".partial", ".crdownload", ".filepart", ".lock", ".!ut")


class PickupRunner:
    """Files everything that is ready, in every configured pickup folder."""

    def __init__(
        self,
        options,
        mapping,
        storages,
        pickups: PickupStore,
        printing=None,
    ):
        # Options snapshot or a callable returning the current one, like the
        # archiver: quarantine list, folders and waiting time are all live.
        self._options = options
        self.mapping = mapping
        self.storages = storages
        self.pickups = pickups
        self.printing = printing
        # Remembers the last problem reported per folder, so one that stays
        # unreachable is logged once instead of on every cycle.
        self._reported: dict[int, str] = {}

    @property
    def options(self):
        return self._options() if callable(self._options) else self._options

    @property
    def blocked_extensions(self) -> frozenset[str]:
        return self.options.blocked_extensions

    @property
    def min_age_seconds(self) -> int:
        return self.options.pickup_min_age

    def problems(self) -> dict[int, str]:
        """The folders that currently have a problem, for the overview page."""
        return dict(self._reported)

    # --- one pass ------------------------------------------------------------

    def run_once(self) -> int:
        """Import everything that is ready. Returns the number of files filed."""
        folders = self.pickups.enabled()
        if not folders:
            return 0
        self.mapping.reload()
        total = 0
        for pickup in folders:
            try:
                total += self._empty(pickup)
            except Exception:  # noqa: BLE001 - one broken folder must not stop the rest
                self._report(pickup, f"Abholen fehlgeschlagen: {self._short(pickup)}")
                logger.exception("Pickup %s failed, retrying next cycle", pickup.name)
        return total

    def _short(self, pickup: Pickup) -> str:
        return f"{pickup.name} ({pickup.folder})"

    def _report(self, pickup: Pickup, problem: str | None) -> None:
        if problem is None:
            if self._reported.pop(pickup.id, None):
                logger.info("Pickup %s: folder is reachable again", pickup.name)
            return
        if self._reported.get(pickup.id) != problem:
            logger.warning("Pickup %s: %s", pickup.name, problem)
            self._reported[pickup.id] = problem

    def _empty(self, pickup: Pickup) -> int:
        source = self.storages.get(pickup.archive)
        target = self.storages.get(pickup.target_archive)

        if pickup.files_into_itself():
            self._report(
                pickup,
                "Zielordner liegt im Abholordner - es wird nichts abgeholt, "
                "sonst wuerde dasselbe Dokument endlos wieder eingelesen",
            )
            return 0

        if not source.folder_exists(pickup.parts):
            # Far friendlier than an error: the device needs the folder to
            # exist before it can write into it, and someone has just said
            # where it should be.
            source.create_folder(pickup.folder)
            self._report(pickup, f"Abholordner {pickup.folder} angelegt - er war noch nicht da")
            return 0
        self._report(pickup, None)
        files = source.list_files(pickup.parts, MAX_DEPTH)

        deadline = time.time() - max(0, self.min_age_seconds)
        filed = 0
        for entry in files:
            if entry.size == 0 or entry.name.lower().endswith(IGNORED_SUFFIXES):
                continue
            if entry.mtime > deadline:
                logger.debug("%s is still being written, waiting", entry.relative)
                continue
            try:
                if self._file_one(pickup, source, target, entry):
                    filed += 1
            except Exception:  # noqa: BLE001 - leave it in place and try again later
                logger.exception(
                    "Pickup %s: could not file %s, leaving it in place",
                    pickup.name,
                    entry.relative,
                )
        return filed

    # --- one document ---------------------------------------------------------

    def _file_one(self, pickup: Pickup, source, target, entry) -> bool:
        rule = None
        if not pickup.has_fixed_target:
            rule = self.mapping.match(entry.name, account_id=pickup.rule_scope())

        quarantined = bool(
            {extension_of(entry.name), extension_of(sanitize_filename(entry.name))}
            & self.blocked_extensions
        )
        if quarantined:
            folder = self.options.quarantine_folder
        elif pickup.has_fixed_target:
            folder = pickup.target_folder
        elif rule is not None:
            folder = rule.folder
        else:
            folder = self.options.fallback_folder

        parts = self._target_parts(folder)
        out_name = self._build_filename(entry, pickup)

        if self.options.dry_run:
            logger.info(
                "[dry-run] would move %s -> %s",
                source.display(entry.parts),
                target.display(parts),
            )
            return False

        # Printing first, and from the source: the document has to be read
        # anyway, and a printer that is out of paper must not stop the filing
        # (nor leave the scan in the folder to be printed again next cycle).
        printer = self._printer_for(pickup, quarantined)
        if printer is not None:
            self.printing.send(
                printer, source.read_bytes(entry.relative), entry.name,
                job_title(pickup.name, entry.name),
            )

        if source is target:
            out_path = target.move_unique(entry.parts, parts, out_name)
        else:
            # Two different servers: no streamed move, so copy the bytes over
            # and only then remove the original.
            out_path = target.save_unique(parts, out_name, source.read_bytes(entry.relative))
            source.remove_file(entry.relative)

        logger.info(
            "Pickup %s: '%s' matched '%s'%s -> %s",
            pickup.name,
            entry.name,
            (rule.keyword if rule else None) or ("<fest>" if pickup.has_fixed_target else "<fallback>"),
            " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
            out_path,
        )
        return True

    def _printer_for(self, pickup: Pickup, quarantined: bool):
        if self.printing is None or not self.options.printing_enabled:
            return None
        if quarantined or not pickup.print_attachments:
            return None
        printer = self.printing.printer_for(pickup.printer)
        if printer is None:
            logger.warning(
                "Pickup %s should print but no usable printer is configured", pickup.name
            )
        return printer

    def _target_parts(self, folder: str) -> tuple[str, ...]:
        from .filenames import safe_relative_parts

        for candidate, note in (
            (folder, None),
            (self.options.fallback_folder, "fallback"),
            ("unsorted", "built-in"),
        ):
            try:
                parts = safe_relative_parts(candidate)
            except ValueError as exc:
                logger.error("Unsafe target folder %r (%s) - not writing there", candidate, exc)
                continue
            if note:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder)
            return parts
        raise ValueError("No usable target folder inside the archive root")

    def _build_filename(self, entry, pickup: Pickup) -> str:
        """Same naming as for mail, with the folder standing in for the sender."""
        filename = sanitize_filename(entry.name)
        mode = self.options.filename_prefix
        if mode == "none":
            return filename
        date_prefix = datetime.fromtimestamp(entry.mtime).strftime("%Y-%m-%d")
        if mode == "date":
            return f"{date_prefix}_{filename}"
        source = sanitize_filename(pickup.name or "scan")
        if mode == "sender":
            return f"{source}_{filename}"
        return f"{date_prefix}_{source}_{filename}"
MAIL2NAS_EOF

# --- mail2nas/web.py ---
cat > mail2nas/web.py <<'MAIL2NAS_EOF'
"""The web UI - where mail2nas is configured, all of it.

Mailboxes, archives, keyword rules, printers, delivery addresses, pickup
folders and the general settings are all edited here and stored in the local
database; the `.env` only says which port this page listens on. A fresh
installation starts with nothing but a password, and the overview page walks
through what is still missing.

Deliberately plain: one password, no user accounts, no JavaScript, no external
assets - so the Content-Security-Policy can forbid everything but inline CSS.

This is a LAN tool. It authenticates with a single password over whatever
transport it is put behind - see the README for why it should not be exposed
to the internet without a TLS-terminating reverse proxy in front.
"""
from __future__ import annotations

import logging
import os
import secrets
import threading
import time
from datetime import datetime, timedelta
from functools import wraps
from types import SimpleNamespace

from flask import (
    Flask,
    abort,
    flash,
    get_flashed_messages,
    redirect,
    render_template_string,
    request,
    session,
    url_for,
)
from markupsafe import Markup
from werkzeug.security import check_password_hash, generate_password_hash

from .mapping import (
    ALL_ACCOUNTS,
    MappingError,
    Rule,
    dump_rules,
    move_rule,
    rules_from_yaml,
    set_account,
    set_archive,
    set_printing,
    validate_folder,
    validate_keyword,
)
from .addresses import AddressError
from .migrate import SETTING_RULES_NOTE
from .options import FILENAME_PREFIXES, LIMITS, OptionsError
from .options import validate as validate_options
from .archives import ArchiveError
from .pickups import PICKUP_INTERVAL, PickupError
from .discovery import discover
from .printers import PrinterError
from .printing import PrintError

logger = logging.getLogger(__name__)

SETTING_PASSWORD_HASH = "web_password_hash"
SETTING_SECRET_KEY = "web_secret_key"
SETTING_SESSION_VERSION = "web_session_version"

MIN_PASSWORD_LENGTH = 8
SESSION_HOURS = 12

# Login throttling. Single-password auth is only as good as the number of
# guesses an attacker gets, so failures cost time after the first few.
MAX_FAILED_LOGINS = 5
LOCKOUT_SECONDS = 60


class LoginThrottle:
    """Per-client failure counter with a fixed lockout window."""

    def __init__(self, max_failures: int = MAX_FAILED_LOGINS, lockout: int = LOCKOUT_SECONDS):
        self._max_failures = max_failures
        self._lockout = lockout
        self._lock = threading.Lock()
        self._state: dict[str, tuple[int, float]] = {}

    def seconds_blocked(self, client: str) -> int:
        with self._lock:
            failures, blocked_until = self._state.get(client, (0, 0.0))
        remaining = blocked_until - time.monotonic()
        return int(remaining) + 1 if failures >= self._max_failures and remaining > 0 else 0

    def record_failure(self, client: str) -> None:
        with self._lock:
            failures, blocked_until = self._state.get(client, (0, 0.0))
            if blocked_until and blocked_until < time.monotonic():
                failures = 0  # previous lockout expired, start over
            failures += 1
            self._state[client] = (failures, time.monotonic() + self._lockout)

    def reset(self, client: str) -> None:
        with self._lock:
            self._state.pop(client, None)


BASE_TEMPLATE = """
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }} - mail2nas</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f7f9; --fg: #1b1d21; --muted: #5c6470; --line: #d7dbe0;
    --card: #ffffff; --accent: #2f6feb; --danger: #b3261e; --ok: #1f7a3d; --warn: #9a6700;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16181c; --fg: #e6e8ea; --muted: #9aa2ad; --line: #2e333a;
      --card: #1e2126; --accent: #6a9bff; --danger: #ef6a63; --ok: #63c98c; --warn: #e3b341;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 1.5rem 1rem 3rem; background: var(--bg); color: var(--fg);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 52rem; margin: 0 auto; }
  h1 { font-size: 1.35rem; margin: 0; }
  h2 { font-size: 1.05rem; margin: 1.75rem 0 .6rem; }
  header { display: flex; flex-wrap: wrap; gap: .75rem; align-items: baseline;
           justify-content: space-between; margin-bottom: 1.25rem; }
  nav a, nav button { color: var(--muted); font-size: .9rem; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
          padding: 1rem 1.1rem; margin-bottom: 1rem; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: .5rem .4rem; border-bottom: 1px solid var(--line);
           vertical-align: middle; }
  th { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
  td.keyword { font-weight: 600; overflow-wrap: break-word; min-width: 9rem; }
  .table-wrap { overflow-x: auto; }
  input, select, button { font: inherit; color: inherit; }
  input[type=text], input[type=password], select {
    background: var(--bg); border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .5rem; width: 100%; max-width: 22rem; }
  button { background: var(--accent); color: #fff; border: 0; border-radius: 6px;
           padding: .45rem .9rem; cursor: pointer; }
  button.secondary { background: transparent; border: 1px solid var(--line); color: var(--fg); }
  button.link { background: none; border: 0; padding: 0; color: var(--muted);
                text-decoration: underline; cursor: pointer; }
  button.danger { background: transparent; border: 1px solid var(--line); color: var(--danger); }
  .row { display: flex; flex-wrap: wrap; gap: .6rem; align-items: flex-end; }
  /* Inside a table cell the select and its button have to stay on one line,
     otherwise every rule takes two rows and the table gets hard to scan. */
  .row.nowrap { flex-wrap: nowrap; gap: .4rem; }
  td select { max-width: 16rem; min-width: 8rem; }
  .field { display: flex; flex-direction: column; gap: .25rem; }
  .field label { font-size: .8rem; color: var(--muted); }
  .hint { color: var(--muted); font-size: .85rem; }
  .msg { border-radius: 8px; padding: .6rem .8rem; margin-bottom: .75rem; border: 1px solid; }
  .msg.error { color: var(--danger); border-color: var(--danger); }
  .msg.ok { color: var(--ok); border-color: var(--ok); }
  .msg.warn { color: var(--warn); border-color: var(--warn); }
  .state-ok { color: var(--ok); font-weight: 600; }
  .state-bad { color: var(--danger); font-weight: 600; }
  .state-wait { color: var(--warn); font-weight: 600; }
  ol.steps li { margin-bottom: .45rem; }
  ol.steps li.done { color: var(--muted); }
  input[type=number] { background: var(--bg); border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .5rem; width: 8rem; }
  textarea { font: inherit; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: .3rem 1rem; margin: 0; font-size: .88rem; }
  dt { color: var(--muted); }
  dd { margin: 0; word-break: break-all; }
  form.inline { display: inline; }
  td.prio { white-space: nowrap; }
  button.arrow { background: transparent; border: 1px solid var(--line); color: var(--fg);
                 padding: .1rem .35rem; line-height: 1.1; }
  button.arrow[disabled] { opacity: .35; cursor: default; }
  code { background: var(--bg); border: 1px solid var(--line); border-radius: 4px;
         padding: 0 .25rem; font-size: .85em; }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <header>
    <h1>mail2nas</h1>
    {% if logged_in %}
    <nav>
      <a href="{{ url_for('overview_page') }}">Uebersicht</a> &middot;
      <a href="{{ url_for('mapping_page') }}">Zuordnungen</a> &middot;
      <a href="{{ url_for('config_page') }}">Konfiguration</a> &middot;
      <a href="{{ url_for('settings_page') }}">Einstellungen</a> &middot;
      <a href="{{ url_for('password_page') }}">Passwort</a> &middot;
      <form class="inline" method="post" action="{{ url_for('logout') }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
        <button class="link" type="submit">Abmelden</button>
      </form>
    </nav>
    {% endif %}
  </header>
  {% if logged_in and setup_hint %}
    <div class="msg warn">{{ setup_hint }}
      <a href="{{ url_for('overview_page') }}">Zur Einrichtung</a></div>
  {% endif %}
  {% for category, message in messages %}
    <div class="msg {{ category }}">{{ message }}</div>
  {% endfor %}
  {{ body }}
</main>
</body>
</html>
"""

LOGIN_BODY = """
<div class="card">
  <h2 style="margin-top:0">Anmelden</h2>
  <form method="post" class="row">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field">
      <label for="password">Passwort</label>
      <input id="password" name="password" type="password" autocomplete="current-password"
             autofocus required>
    </div>
    <button type="submit">Anmelden</button>
  </form>
</div>
"""

MAPPING_BODY = """
{% if migration_note %}
<div class="msg warn">{{ migration_note }}
  <form class="inline" method="post" action="{{ url_for('dismiss_migration_note') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="link" type="submit">Ausblenden</button>
  </form>
</div>
{% endif %}
{% if not storage_ok %}
<div class="msg warn">Das Standard-Archiv ist nicht erreichbar oder noch nicht eingerichtet -
  die Ordnerliste bleibt leer. Neue Ordner lassen sich trotzdem eintragen; sie werden
  beim ersten Anhang angelegt.</div>
{% endif %}
<div class="card">
  <h2 style="margin-top:0">Stichwort einem Ordner zuordnen</h2>
  <form method="post" action="{{ url_for('add_rule') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="keyword">Stichwort in Betreff oder Dateiname</label>
        <input id="keyword" name="keyword" type="text" placeholder="z. B. Rechnung" required>
      </div>
      <div class="field">
        <label for="folder">Zielordner</label>
        <select id="folder" name="folder">
          <option value="">-- vorhandenen Ordner waehlen --</option>
          {% for folder in folders %}
            <option value="{{ folder }}">{{ folder }}</option>
          {% endfor %}
        </select>
      </div>
      <div class="field">
        <label for="new_folder">oder neuen Ordner anlegen</label>
        <input id="new_folder" name="new_folder" type="text" placeholder="z. B. rechnungen/2026">
      </div>
      {% if accounts|length > 1 %}
      <div class="field">
        <label for="account">Postfach</label>
        <select id="account" name="account">
          <option value="all">alle Postfaecher</option>
          {% for account in accounts %}
            <option value="{{ account.key }}">{{ account.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
            <option value="{{ entry.key }}">{{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      {% if printers %}
      <div class="field">
        <label for="printer">Drucken</label>
        <select id="printer" name="printer">
          <option value="">nicht drucken</option>
          <option value="account">drucken, Drucker des Postfachs</option>
          {% for printer in printers %}
            <option value="{{ printer.key }}">drucken auf {{ printer.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <button type="submit">Hinzufuegen</button>
    </div>
  </form>
  <p class="hint">Gross-/Kleinschreibung ist egal. <code>*</code> steht fuer beliebig
  viele Zeichen, <code>?</code> fuer genau eines - <code>RE*2026</code> passt also auf
  &bdquo;RE-4711 vom 03.2026&ldquo;. Aenderungen wirken beim naechsten Durchlauf,
  ein Neustart ist nicht noetig.</p>
  {% if printers %}
  <p class="hint">Mit <em>Drucken</em> wird jeder Anhang, den diese Zuordnung trifft,
  zusaetzlich ausgedruckt - z. B. nur Rechnungen. Gedruckt wird erst, nachdem der
  Anhang abgelegt wurde. Drucker werden unter
  <a href="{{ url_for('config_page') }}">Konfiguration</a> angelegt.</p>
  {% endif %}
</div>

<div class="card">
  <h2 style="margin-top:0">Aktuelle Zuordnungen ({{ rules|length }})</h2>
  {% if rules %}
  <p class="hint" style="margin-top:0">Von oben nach unten geprueft - die erste
  passende Zuordnung gewinnt. Mit den Pfeilen verschieben.</p>
  <div class="table-wrap">
  <table>
    <tr>
      <th>Prio</th><th>Stichwort</th>
      <th>Ziel{% if accounts|length > 1 %}, Postfach{% endif %}{% if printers %} und Druck{% endif %}</th>
      <th></th>
    </tr>
    {% for rule in rules %}
    <tr>
      <td class="prio">
        <form class="inline" method="post" action="{{ url_for('move_rule_up') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <button class="arrow" type="submit" title="nach oben"
                  {% if loop.first %}disabled{% endif %}>&uarr;</button>
        </form>
        <form class="inline" method="post" action="{{ url_for('move_rule_down') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <button class="arrow" type="submit" title="nach unten"
                  {% if loop.last %}disabled{% endif %}>&darr;</button>
        </form>
        <span class="hint">{{ loop.index }}</span>
      </td>
      <td class="keyword">{{ rule.keyword }}</td>
      <td>
        <form method="post" action="{{ url_for('update_rule') }}" class="row nowrap">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <select name="folder">
            {% for option in folder_options(rule.folder) %}
              <option value="{{ option }}" {% if option == rule.folder %}selected{% endif %}>{{ option }}</option>
            {% endfor %}
          </select>
          {% if accounts|length > 1 %}
          <select name="account">
            <option value="all" {% if rule.account == 'all' %}selected{% endif %}>alle Postfaecher</option>
            {% for account in accounts %}
              <option value="{{ account.key }}"
                {% if rule.account == account.key %}selected{% endif %}>{{ account.name }}</option>
            {% endfor %}
            {% if rule.account not in account_keys %}
              <option value="{{ rule.account }}" selected>(geloeschtes Postfach)</option>
            {% endif %}
          </select>
          {% endif %}
          {% if archives|length > 1 %}
          <input type="hidden" name="archive_fields" value="1">
          <select name="archive" title="Archiv, auf dem der Zielordner liegt">
            <option value="" {% if not rule.archive %}selected{% endif %}>Standard-Archiv</option>
            {% for entry in archives %}
              <option value="{{ entry.key }}"
                {% if rule.archive == entry.key %}selected{% endif %}>{{ entry.name }}</option>
            {% endfor %}
            {% if rule.archive and rule.archive not in archive_keys %}
              <option value="{{ rule.archive }}" selected>(geloeschtes Archiv)</option>
            {% endif %}
          </select>
          {% endif %}
          {% if printers %}
          <input type="hidden" name="print_fields" value="1">
          <select name="printer" title="Anhaenge dieser Zuordnung drucken">
            <option value="" {% if not rule.print_attachments %}selected{% endif %}>nicht drucken</option>
            <option value="account"
              {% if rule.print_attachments and not rule.printer %}selected{% endif %}>drucken, Drucker des Postfachs</option>
            {% for printer in printers %}
              <option value="{{ printer.key }}"
                {% if rule.print_attachments and rule.printer == printer.key %}selected{% endif %}>drucken auf {{ printer.name }}</option>
            {% endfor %}
            {% if rule.printer and rule.printer not in printer_keys %}
              <option value="{{ rule.printer }}" selected>(geloeschter Drucker)</option>
            {% endif %}
          </select>
          {% endif %}
          <button class="secondary" type="submit">Speichern</button>
        </form>
      </td>
      <td>
        <form method="post" action="{{ url_for('delete_rule') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <button class="danger" type="submit">Loeschen</button>
        </form>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Noch keine Zuordnung. Ohne Treffer landet alles im
  Fallback-Ordner <strong>{{ fallback_folder }}</strong>.</p>
  {% endif %}
</div>

<div class="card">
  <h2 style="margin-top:0">Sichern und uebertragen</h2>
  <p class="hint" style="margin-top:0">Die Zuordnungen liegen in der Datenbank des
  Containers. Als Datei exportiert sind sie eine lesbare Sicherung - und lassen sich
  in eine andere Installation uebernehmen.</p>
  <p><a href="{{ url_for('export_rules') }}"><button class="secondary" type="button">
    Als mapping.yaml herunterladen</button></a></p>
  <form method="post" action="{{ url_for('import_rules') }}" enctype="multipart/form-data">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="rules_file">mapping.yaml importieren</label>
        <input id="rules_file" name="rules_file" type="file" accept=".yaml,.yml,.txt" required>
      </div>
      <div class="field">
        <label for="import_mode">Vorhandene Zuordnungen</label>
        <select id="import_mode" name="mode">
          <option value="append">behalten, neue anhaengen</option>
          <option value="replace">ersetzen</option>
        </select>
      </div>
      <button type="submit">Importieren</button>
    </div>
  </form>
  <p class="hint" style="margin-bottom:0">Gelesen werden das aktuelle Format und das alte
  (<code>Stichwort: ordner</code>). Beim Anhaengen werden Stichwoerter, die es schon gibt,
  uebersprungen. Ohne Treffer landet alles in <strong>{{ fallback_folder }}</strong>,
  gesperrte Dateitypen in <strong>{{ quarantine_folder }}</strong>.</p>
</div>
"""

CONFIG_BODY = """
<div class="card">
  <h2 style="margin-top:0">Postfaecher</h2>
  {% if accounts %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Postfach</th><th>Ordner</th><th>Modus</th><th>Status</th><th></th></tr>
    {% for account in accounts %}
    <tr>
      <td class="keyword">{{ account.name }}</td>
      <td>{{ account.user }}<br><span class="hint">{{ account.host }}:{{ account.port }}{%
        if not account.ssl %} &middot; ohne TLS{% endif %}</span></td>
      <td>{{ account.folder }}</td>
      <td>{{ account.mode }}</td>
      <td>{% if account.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_account', account_id=account.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Kein Postfach konfiguriert - es wird nichts abgeholt.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_account') }}">
    <button type="button">Postfach hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Drucker</h2>
  {% if printers %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Warteschlange</th><th>Optionen</th><th>Status</th><th></th></tr>
    {% for printer in printers %}
    <tr>
      <td class="keyword">{{ printer.name }}</td>
      <td>{{ printer.destination }}{% if printer.server %}<br>
        <span class="hint">auf {{ printer.server }}</span>{% endif %}</td>
      <td>{{ printer.options or '-' }}{% if printer.copies > 1 %}
        <span class="hint">&middot; {{ printer.copies }} Kopien</span>{% endif %}</td>
      <td>{% if printer.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_printer', printer_id=printer.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Einmal angelegt, dann ueberall per Auswahlfeld verwendbar: je
  Postfach (alles drucken) und je Zuordnung (z. B. nur Rechnungen).</p>
  {% elif printing_enabled %}
  <p class="hint">Kein Drucker angelegt - es wird nichts gedruckt. Ein Drucker ist eine
  CUPS-Warteschlange; der Name ist derselbe wie in CUPS (<code>lpstat -p</code>).</p>
  {% else %}
  <p class="hint">Drucken ist unter <a href="{{ url_for('settings_page') }}">Einstellungen</a>
  abgeschaltet.</p>
  {% endif %}
  <p style="margin-bottom:0">
    <a href="{{ url_for('new_printer') }}">
      <button type="button">Drucker hinzufuegen</button></a>
    <a href="{{ url_for('discover_printers') }}">
      <button class="secondary" type="button">Im Netzwerk suchen</button></a>
  </p>
</div>

<div class="card">
  <h2 style="margin-top:0">Archive</h2>
  {% if archives %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Ort</th><th>Art</th><th>Status</th><th></th></tr>
    {% for entry in archives %}
    <tr>
      <td class="keyword">{{ entry.name }}{% if loop.first %}
        <span class="hint">Standard</span>{% endif %}</td>
      <td>{{ entry.location() }}</td>
      <td>{% if entry.backend == 'smb' %}SMB{% else %}gemountet{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_archive', archive_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Das erste aktive Archiv ist das Standard-Archiv: dorthin geht alles
  ohne eigene Angabe. Zuordnungen, Zustelladressen und Abholordner koennen jeweils ein
  anderes waehlen.</p>
  {% else %}
  <p class="hint"><strong>Noch kein Archiv eingerichtet</strong> - solange wird nichts
  abgeholt. Meist ist das eine SMB-Freigabe auf dem NAS; gemountet werden muss dafuer
  nichts.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_archive') }}">
    <button type="button">Archiv hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Abholordner (Scan-to-Folder)</h2>
  {% if pickups %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Ordner</th><th>Ziel</th><th>Drucken</th><th>Status</th><th></th></tr>
    {% for entry in pickups %}
    <tr>
      <td class="keyword">{{ entry.name }}</td>
      <td>{{ entry.folder }}{% if entry.archive_label %}
        <span class="hint">auf {{ entry.archive_label }}</span>{% endif %}</td>
      <td>{{ entry.target_folder or 'nach Stichwoertern' }}{% if entry.target_archive_label %}
        <span class="hint">auf {{ entry.target_archive_label }}</span>{% endif %}</td>
      <td>{% if entry.print_attachments %}{{ entry.printer_label or 'ja' }}{% else %}nein{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_pickup', pickup_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Fertige Dateien werden von dort ins Archiv <em>verschoben</em> -
  ganz ohne Postfach. Geprueft wird alle {{ pickup_interval }} Sekunden.</p>
  {% else %}
  <p class="hint">Kein Abholordner eingerichtet. Fuer Geraete, die Scans per SMB
  ablegen statt sie zu mailen: Ordner eintragen, mail2nas raeumt ihn ab.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_pickup') }}">
    <button type="button">Abholordner hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Zustelladressen</h2>
  {% if address_rules %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Empfaenger</th><th>Absender</th><th>Drucken</th><th>Ablegen</th>
      <th>Status</th><th></th></tr>
    {% for entry in address_rules %}
    <tr>
      <td class="keyword">{{ entry.name }}</td>
      <td>{{ entry.recipient or 'alle' }}</td>
      <td>{{ entry.sender or 'alle' }}</td>
      <td>{% if entry.print_attachments %}ja{% if entry.printer_label %}
        <span class="hint">&middot; {{ entry.printer_label }}</span>{% endif %}
        {% else %}nein{% endif %}</td>
      <td>{% if entry.archive_attachments %}ja{% if entry.folder %}
        <span class="hint">&middot; {{ entry.folder }}</span>{% endif %}{% if entry.archive_label %}
        <span class="hint">&middot; {{ entry.archive_label }}</span>{% endif %}
        {% else %}nein{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_address', address_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Die erste passende Zustelladresse gewinnt. Sie entscheidet ueber
  Drucken und Ablegen; die Stichwort-Zuordnungen bestimmen dann nur noch den
  Zielordner, falls hier keiner steht.</p>
  {% else %}
  <p class="hint">Keine Zustelladresse angelegt. Damit wird nur nach Stichwoertern
  sortiert und nur gedruckt, was ein Postfach oder eine Zuordnung verlangt.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_address') }}">
    <button type="button">Zustelladresse hinzufuegen</button></a></p>
</div>

<p class="hint">Allgemeine Einstellungen - Ordner fuer Unsortiertes und Quarantaene,
Grenzwerte, gesperrte Dateitypen, Abrufintervall, Testmodus - stehen unter
<a href="{{ url_for('settings_page') }}">Einstellungen</a>.</p>
"""

ACCOUNT_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Postfach bearbeiten' if account else 'Postfach hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ account.name if account else '' }}"
               placeholder="z. B. Buchhaltung" required>
      </div>
      <div class="field">
        <label for="host">IMAP-Server</label>
        <input id="host" name="host" type="text" value="{{ account.host if account else '' }}"
               placeholder="imap.example.com" required>
      </div>
      <div class="field">
        <label for="port">Port</label>
        <input id="port" name="port" type="text" value="{{ account.port if account else '993' }}" required>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="user">Benutzer</label>
        <input id="user" name="user" type="text" value="{{ account.user if account else '' }}" required>
      </div>
      <div class="field">
        <label for="password">Passwort</label>
        <input id="password" name="password" type="password" autocomplete="new-password"
               {% if account %}placeholder="unveraendert lassen: leer"{% else %}required{% endif %}>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="folder">Zu ueberwachender Ordner</label>
        <input id="folder" name="folder" type="text"
               value="{{ account.folder if account else 'INBOX' }}" required>
      </div>
      <div class="field">
        <label for="mode">Abrufmodus</label>
        <select id="mode" name="mode">
          <option value="idle" {% if account and account.mode == 'idle' %}selected{% endif %}>IDLE (Push)</option>
          <option value="poll" {% if not account or account.mode == 'poll' %}selected{% endif %}>Polling</option>
        </select>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="processed_folder">Verarbeitete Mails verschieben nach (optional)</label>
        <input id="processed_folder" name="processed_folder" type="text"
               value="{{ account.processed_folder if account else '' }}">
      </div>
      <div class="field">
        <label for="oversized_folder">Zu grosse Mails verschieben nach (optional)</label>
        <input id="oversized_folder" name="oversized_folder" type="text"
               value="{{ account.oversized_folder if account else '' }}">
      </div>
    </div>
    <p style="margin:.8rem 0 .2rem">
      <label><input type="checkbox" name="ssl" value="1"
        {% if not account or account.ssl %}checked{% endif %}> TLS/SSL verwenden</label>
      &nbsp;&nbsp;
      <label><input type="checkbox" name="enabled" value="1"
        {% if not account or account.enabled %}checked{% endif %}> Postfach aktiv</label>
    </p>

    {% if printers %}
    <input type="hidden" name="print_fields" value="1">
    <h2>Drucken und Ablegen</h2>
    <div class="row">
      <div class="field">
        <label for="account_printer">Drucker fuer dieses Postfach</label>
        <select id="account_printer" name="printer">
          <option value="">kein Drucker</option>
          {% for printer in printers %}
            <option value="{{ printer.key }}"
              {% if account and account.printer == printer.key %}selected{% endif %}>{{ printer.name }}</option>
          {% endfor %}
          {% if account and account.printer and account.printer not in printer_keys %}
            <option value="{{ account.printer }}" selected>(geloeschter Drucker)</option>
          {% endif %}
        </select>
      </div>
    </div>
    <p style="margin:.6rem 0 .2rem">
      <label><input type="checkbox" name="print_attachments" value="1"
        {% if account and account.print_attachments %}checked{% endif %}>
        Alle Anhaenge dieses Postfachs drucken</label>
    </p>
    <p style="margin:.2rem 0 .2rem">
      <label><input type="checkbox" name="archive_attachments" value="1"
        {% if not account or account.archive_attachments %}checked{% endif %}>
        Anhaenge im Archiv ablegen</label>
    </p>
    <p class="hint">Ohne Haken bei &bdquo;ablegen&ldquo; wird nur gedruckt und nichts
    gespeichert. Anhaenge mit gesperrter Dateiendung landen trotzdem im
    Quarantaene-Ordner - gedruckt werden sie nie. Einzelne Zuordnungen koennen
    zusaetzlich drucken, auch auf einem anderen Drucker.</p>
    {% endif %}

    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Aenderungen greifen innerhalb weniger Sekunden; eine laufende
  IMAP-Verbindung wird dafuer neu aufgebaut.</p>
</div>

{% if account %}
<div class="card">
  <h2 style="margin-top:0">Verbindung testen</h2>
  <form method="post" action="{{ url_for('test_account', account_id=account.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Anmeldung und Ordner pruefen</button>
    <p class="hint">Meldet sich mit den gespeicherten Daten an und oeffnet den Ordner -
    liest und veraendert keine Mail.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Postfach loeschen</h2>
  <form method="post" action="{{ url_for('delete_account', account_id=account.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Dieses Postfach loeschen</button>
    <p class="hint">Zuordnungen, die nur fuer dieses Postfach gelten, bleiben
    bestehen und greifen dann nicht mehr.</p>
  </form>
</div>
{% endif %}
"""

PRINTER_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Drucker bearbeiten' if printer else 'Drucker hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ printer.name if printer else '' }}"
               placeholder="z. B. Buero EG" required>
      </div>
      <div class="field">
        <label for="destination">Warteschlange in CUPS</label>
        <input id="destination" name="destination" type="text"
               value="{{ printer.destination if printer else '' }}"
               placeholder="z. B. Kyocera_M2540" required>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="server">CUPS-Server (optional)</label>
        <input id="server" name="server" type="text" value="{{ printer.server if printer else '' }}"
               placeholder="leer = lokaler cupsd, sonst z. B. cups.lan:631">
      </div>
      <div class="field">
        <label for="copies">Kopien</label>
        <input id="copies" name="copies" type="text" value="{{ printer.copies if printer else '1' }}">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="options">Druckoptionen (optional)</label>
        <input id="options" name="options" type="text"
               value="{{ printer.options if printer else '' }}"
               placeholder="z. B. media=A4 sides=two-sided-long-edge">
      </div>
    </div>
    <p style="margin:.8rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not printer or printer.enabled %}checked{% endif %}> Drucker aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Die Warteschlange ist der Name, unter dem der Drucker in CUPS
  bekannt ist (<code>lpstat -p</code>). Die Optionen sind genau die, die
  <code>lp -o</code> versteht - jeweils ohne <code>-o</code>, mehrere durch
  Leerzeichen getrennt.</p>
</div>

{% if printer and printer.id %}
<div class="card">
  <h2 style="margin-top:0">Testdruck</h2>
  <form method="post" action="{{ url_for('test_printer', printer_id=printer.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Testseite drucken</button>
    <p class="hint">Druckt eine Seite mit den Einstellungen dieses Druckers - so
    laesst sich pruefen, ob die Warteschlange stimmt, bevor die erste Rechnung
    ankommt.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Drucker loeschen</h2>
  <form method="post" action="{{ url_for('delete_printer', printer_id=printer.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diesen Drucker loeschen</button>
    <p class="hint">Postfaecher und Zuordnungen, die auf ihn zeigen, drucken danach
    nicht mehr - das steht dann im Log.</p>
  </form>
</div>
{% endif %}
"""

ADDRESS_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Zustelladresse bearbeiten' if entry else 'Zustelladresse hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ entry.name if entry else '' }}"
               placeholder="z. B. Drucker Buero">
      </div>
      <div class="field">
        <label for="recipient">Empfaengeradresse</label>
        <input id="recipient" name="recipient" type="text"
               value="{{ entry.recipient if entry else '' }}"
               placeholder="drucker@firma.de, @firma.de oder drucker-*@firma.de">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="sender">Nur von diesem Absender (optional)</label>
        <input id="sender" name="sender" type="text" value="{{ entry.sender if entry else '' }}"
               placeholder="leer = von jedem; sonst z. B. @firma.de">
      </div>
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="print_attachments" value="1"
        {% if not entry or entry.print_attachments %}checked{% endif %}>
        Anhaenge drucken</label>
    </p>
    <div class="field">
      <label for="printer">Drucker</label>
      <select id="printer" name="printer">
        <option value="">Drucker des Postfachs</option>
        {% for printer in printers %}
        <option value="{{ printer.key }}"
          {% if entry and entry.printer == printer.key %}selected{% endif %}>
          {{ printer.label() }}</option>
        {% endfor %}
        {% if entry and entry.printer and entry.printer not in printer_keys %}
        <option value="{{ entry.printer }}" selected>(geloeschter Drucker)</option>
        {% endif %}
      </select>
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="archive_attachments" value="1"
        {% if not entry or entry.archive_attachments %}checked{% endif %}>
        Anhaenge per SMB ablegen</label>
    </p>
    <div class="row">
      <div class="field">
        <label for="folder">Zielordner (optional)</label>
        <input id="folder" name="folder" type="text" value="{{ entry.folder if entry else '' }}"
               placeholder="leer = nach Stichwort-Zuordnungen">
      </div>
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for item in archives %}
          <option value="{{ item.key }}"
            {% if entry and entry.archive == item.key %}selected{% endif %}>{{ item.name }}</option>
          {% endfor %}
          {% if entry and entry.archive and entry.archive not in archive_keys %}
          <option value="{{ entry.archive }}" selected>(geloeschtes Archiv)</option>
          {% endif %}
        </select>
      </div>
      {% endif %}
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not entry or entry.enabled %}checked{% endif %}> Aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Gepruefte Kopfzeilen sind Delivered-To, X-Original-To, Envelope-To,
  To und Cc - ein Alias, das in dieses Postfach zugestellt wird, wird also auch
  dann erkannt, wenn im To: etwas anderes steht. Sind Empfaenger- und
  Absenderadresse gesetzt, muessen beide passen; der Absender wirkt dann als
  Schutz davor, dass Fremde ueber die Adresse drucken koennen.</p>
</div>

{% if entry %}
<div class="card">
  <h2 style="margin-top:0">Zustelladresse loeschen</h2>
  <form method="post" action="{{ url_for('delete_address', address_id=entry.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diese Zustelladresse loeschen</button>
    <p class="hint">Mail an diese Adresse wird danach wieder wie jede andere
    behandelt.</p>
  </form>
</div>
{% endif %}
"""

DISCOVERY_BODY = """
<div class="card">
  <h2 style="margin-top:0">Drucker im Netzwerk suchen</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="server">CUPS-Server abfragen (optional)</label>
        <input id="server" name="server" type="text" value="{{ server }}"
               placeholder="z. B. cups.lan:631 - leer = lokaler cupsd">
      </div>
      <button type="submit">Suchen</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Zurueck</button></a>
    </div>
    <p class="hint" style="margin-bottom:0">Gefragt werden die Warteschlangen des
    CUPS-Servers und - per mDNS - Geraete, die sich im Netz selbst ankuendigen.</p>
  </form>
</div>

{% if searched %}
<div class="card">
  <h2 style="margin-top:0">Gefunden</h2>
  {% if found %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Warteschlange</th><th>Server</th><th>Quelle</th><th></th></tr>
    {% for item in found %}
    <tr>
      <td class="keyword">{{ item.name }}</td>
      <td>{{ item.destination }}<br><span class="hint">{{ item.detail }}</span></td>
      <td>{{ item.server or 'lokal' }}</td>
      <td>{% if item.ready_to_use %}CUPS-Warteschlange{% else %}im Netz gefunden{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('new_printer', name=item.name, destination=item.destination,
                            server=item.server) }}">Uebernehmen</a>
      </td>
    </tr>
    {% if not item.ready_to_use %}
    <tr><td colspan="5" class="hint">Noch keine Warteschlange. Zuverlaessig wird daraus
      eine mit:<br><code>{{ item.lpadmin_command() }}</code></td></tr>
    {% endif %}
    {% endfor %}
  </table>
  </div>
  <p class="hint">„Uebernehmen" fuellt das Drucker-Formular vor. Danach einmal die
  Testseite drucken - das ist der schnellste Weg zu wissen, ob der Weg stimmt.</p>
  {% else %}
  <p class="hint">Nichts gefunden.</p>
  {% endif %}
  {% for problem in problems %}
  <p class="hint">{{ problem }}</p>
  {% endfor %}
</div>
{% endif %}
"""

ARCHIVE_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Archiv bearbeiten' if archive else 'Archiv hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ archive.name if archive else '' }}"
               placeholder="z. B. NAS Buero">
      </div>
      <div class="field">
        <label for="backend">Art</label>
        <select id="backend" name="backend">
          <option value="smb" {% if not archive or archive.backend == 'smb' %}selected{% endif %}>
            SMB-Freigabe (nichts gemountet)</option>
          <option value="local" {% if archive and archive.backend == 'local' %}selected{% endif %}>
            Gemountetes Verzeichnis</option>
        </select>
      </div>
    </div>

    <p class="hint" style="margin:.9rem 0 .2rem"><strong>Nur fuer SMB:</strong></p>
    <div class="row">
      <div class="field">
        <label for="host">Server (NAS)</label>
        <input id="host" name="host" type="text" value="{{ archive.host if archive else '' }}"
               placeholder="nas.lan oder 192.168.1.10">
      </div>
      <div class="field">
        <label for="share">Freigabe</label>
        <input id="share" name="share" type="text" value="{{ archive.share if archive else '' }}"
               placeholder="z. B. Belege">
      </div>
      <div class="field">
        <label for="root">Unterordner (optional)</label>
        <input id="root" name="root" type="text" value="{{ archive.root if archive else '' }}"
               placeholder="z. B. archiv/2026">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="user">Benutzer</label>
        <input id="user" name="user" type="text" value="{{ archive.user if archive else '' }}">
      </div>
      <div class="field">
        <label for="password">Passwort{% if archive %}
          <span class="hint">(leer = unveraendert)</span>{% endif %}</label>
        <input id="password" name="password" type="password" autocomplete="new-password">
      </div>
      <div class="field">
        <label for="domain">Domain (optional)</label>
        <input id="domain" name="domain" type="text" value="{{ archive.domain if archive else '' }}">
      </div>
      <div class="field">
        <label for="port">Port</label>
        <input id="port" name="port" type="text" value="{{ archive.port if archive else '445' }}">
      </div>
    </div>
    <p style="margin:.6rem 0 .2rem">
      <label><input type="checkbox" name="encrypt" value="1"
        {% if not archive or archive.encrypt %}checked{% endif %}> Verbindung verschluesseln
        (SMB3; abschalten, wenn der Server das ablehnt)</label>
    </p>

    <p class="hint" style="margin:.9rem 0 .2rem"><strong>Nur fuer ein gemountetes
    Verzeichnis:</strong></p>
    <div class="field">
      <label for="path">Pfad</label>
      <input id="path" name="path" type="text" value="{{ archive.path if archive else '' }}"
             placeholder="/mnt/nas2">
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not archive or archive.enabled %}checked{% endif %}> Archiv aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Das <strong>erste aktive</strong> Archiv ist das Standard-Archiv: dorthin
  geht alles, was kein eigenes Archiv nennt, und dort liegen der Fallback- und der
  Quarantaene-Ordner.
  Ein gemountetes Verzeichnis muss vom Betriebssystem eingebunden sein - mail2nas
  mountet nichts.</p>
</div>

{% if archive %}
<div class="card">
  <h2 style="margin-top:0">Verbindung testen</h2>
  <form method="post" action="{{ url_for('test_archive', archive_id=archive.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Verbindung testen</button>
    <p class="hint">Schreibt eine winzige Testdatei und loescht sie wieder - so steht
    fest, dass Zugangsdaten und Schreibrechte stimmen, bevor die erste Rechnung
    kommt.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Archiv loeschen</h2>
  <form method="post" action="{{ url_for('delete_archive', archive_id=archive.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Dieses Archiv loeschen</button>
    <p class="hint">Die Dateien darauf bleiben unangetastet. Zuordnungen und Adressen,
    die darauf zeigten, nutzen danach das Standard-Archiv.</p>
  </form>
</div>
{% endif %}
"""

PICKUP_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Abholordner bearbeiten' if pickup else 'Abholordner hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ pickup.name if pickup else '' }}"
               placeholder="z. B. Kopierer Flur">
      </div>
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv, auf dem der Ordner liegt</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
          <option value="{{ entry.key }}"
            {% if pickup and pickup.archive == entry.key %}selected{% endif %}>{{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <div class="field">
        <label for="folder">Abholordner</label>
        <input id="folder" name="folder" type="text" value="{{ pickup.folder if pickup else '' }}"
               placeholder="z. B. scans/kopierer-flur" required>
      </div>
    </div>

    <div class="row" style="margin-top:.6rem">
      {% if archives|length > 1 %}
      <div class="field">
        <label for="target_archive">Zielarchiv</label>
        <select id="target_archive" name="target_archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
          <option value="{{ entry.key }}"
            {% if pickup and pickup.target_archive == entry.key %}selected{% endif %}>
            {{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <div class="field">
        <label for="target_folder">Zielordner <span class="hint">(leer = nach Stichwoertern)</span></label>
        <input id="target_folder" name="target_folder" type="text"
               value="{{ pickup.target_folder if pickup else '' }}" placeholder="z. B. scans">
      </div>
      {% if printers %}
      <div class="field">
        <label for="printer">Drucken</label>
        <select id="printer" name="printer">
          <option value="">nicht drucken</option>
          {% for printer in printers %}
          <option value="{{ printer.key }}"
            {% if pickup and pickup.print_attachments and pickup.printer == printer.key %}selected{% endif %}>
            drucken auf {{ printer.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not pickup or pickup.enabled %}checked{% endif %}> Ordner ueberwachen</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Der Ordner ist ein <strong>Postausgang, kein Archiv</strong>: was
  abgeholt wurde, wird von dort <em>verschoben</em>. Angefasst wird eine Datei erst,
  wenn sie {{ min_age }} Sekunden unveraendert ist - sonst landet eine noch laufende
  Uebertragung im Archiv. Unterordner werden mitgelesen; versteckte und halbfertige
  Dateien (<code>.tmp</code>, <code>.part</code>) bleiben liegen.</p>
  <p class="hint">Ohne Zielordner entscheiden die Stichwort-Zuordnungen - dabei greifen
  nur die fuer „alle Postfaecher", denn eine Datei aus einem Ordner gehoert zu keinem
  Postfach. Gesperrte Dateiendungen kommen auch hier in die Quarantaene.</p>
</div>

{% if pickup %}
<div class="card">
  <h2 style="margin-top:0">Abholordner loeschen</h2>
  <form method="post" action="{{ url_for('delete_pickup', pickup_id=pickup.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diesen Abholordner loeschen</button>
    <p class="hint">Der Ordner selbst und alles darin bleiben unangetastet - es wird
    nur nicht mehr hineingesehen.</p>
  </form>
</div>
{% endif %}
"""

OVERVIEW_BODY = """
{% if initial_password %}
<div class="msg warn">Angemeldet mit dem automatisch erzeugten Startpasswort. Bitte unter
  <a href="{{ url_for('password_page') }}">Passwort</a> ein eigenes setzen.</div>
{% endif %}

{% if steps_open %}
<div class="card">
  <h2 style="margin-top:0">Einrichtung</h2>
  <ol class="steps">
    {% for step in steps %}
    <li class="{{ 'done' if step.done }}">
      {% if step.done %}&#10003;{% endif %}
      <a href="{{ step.url }}">{{ step.title }}</a> - <span class="hint">{{ step.hint }}</span>
    </li>
    {% endfor %}
  </ol>
  <p class="hint" style="margin-bottom:0">Alles wird hier eingestellt und sofort
  uebernommen - ein Neustart des Containers ist nie noetig.</p>
</div>
{% endif %}

<div class="card">
  <h2 style="margin-top:0">Status</h2>
  <table>
    <tr><th>Was</th><th>Zustand</th><th>Details</th></tr>
    <tr>
      <td class="keyword">Standard-Archiv</td>
      <td>{% if archive_status.ok %}<span class="state-ok">bereit</span>
          {% elif archive_status.ok is none %}<span class="state-wait">wird geprueft</span>
          {% else %}<span class="state-bad">nicht bereit</span>{% endif %}</td>
      <td>{{ archive_status.detail or '-' }}</td>
    </tr>
    {% for row in workers %}
    <tr>
      <td class="keyword">{{ row.label }}</td>
      <td>{% if row.state == 'verbunden' %}<span class="state-ok">verbunden</span>
          {% elif row.state == 'Fehler' %}<span class="state-bad">Fehler</span>
          {% else %}<span class="state-wait">{{ row.state }}</span>{% endif %}</td>
      <td>{% if row.detail %}{{ row.detail }}{% endif %}
          {% if row.processed %}<span class="hint">&middot; {{ row.processed }} verarbeitet</span>{% endif %}
          {% if row.last_ok %}<span class="hint">&middot; zuletzt ok {{ row.last_ok }}</span>{% endif %}
          {% if row.last_error %}<br><span class="state-bad">{{ row.last_error }}</span>
            <span class="hint">({{ row.last_error_at }})</span>{% endif %}</td>
    </tr>
    {% endfor %}
    {% for problem in pickup_problems %}
    <tr><td class="keyword">Abholordner</td><td><span class="state-bad">Problem</span></td>
      <td>{{ problem }}</td></tr>
    {% endfor %}
  </table>
  {% if not workers and ready %}
  <p class="hint">Kein aktives Postfach - es wird keine Mail abgeholt.</p>
  {% endif %}
  {% if dry_run %}
  <p class="state-wait">Testmodus ist an: es wird nichts abgelegt, gedruckt oder als
  gelesen markiert, nur protokolliert.</p>
  {% endif %}
  <p class="hint" style="margin-bottom:0">Stand {{ now }} &middot; laeuft seit {{ started }}.
  Details stehen im Container-Log (<code>docker compose logs -f</code>).</p>
</div>

<div class="card">
  <h2 style="margin-top:0">Auf einen Blick</h2>
  <dl>
    <dt>Postfaecher</dt><dd>{{ counts.accounts }}</dd>
    <dt>Archive</dt><dd>{{ counts.archives }}</dd>
    <dt>Zuordnungen</dt><dd>{{ counts.rules }}</dd>
    <dt>Drucker</dt><dd>{{ counts.printers }}</dd>
    <dt>Zustelladressen</dt><dd>{{ counts.addresses }}</dd>
    <dt>Abholordner</dt><dd>{{ counts.pickups }}</dd>
  </dl>
</div>
"""

SETTINGS_BODY = """
<form method="post">
  <input type="hidden" name="csrf_token" value="{{ csrf_token }}">

  <div class="card">
    <h2 style="margin-top:0">Ablage</h2>
    <div class="row">
      <div class="field">
        <label for="fallback_folder">Ordner fuer Anhaenge ohne Treffer</label>
        <input id="fallback_folder" name="fallback_folder" type="text" value="{{ o.fallback_folder }}">
      </div>
      <div class="field">
        <label for="quarantine_folder">Quarantaene-Ordner</label>
        <input id="quarantine_folder" name="quarantine_folder" type="text"
               value="{{ o.quarantine_folder }}">
      </div>
      <div class="field">
        <label for="filename_prefix">Dateiname beginnt mit</label>
        <select id="filename_prefix" name="filename_prefix">
          {% for value, text in prefixes.items() %}
            <option value="{{ value }}" {% if o.filename_prefix == value %}selected{% endif %}>{{ text }}</option>
          {% endfor %}
        </select>
      </div>
    </div>
    <p style="margin:.7rem 0 .2rem"><label><input type="checkbox" name="match_body" value="1"
      {% if o.match_body %}checked{% endif %}> Stichwoerter auch im Mailtext suchen
      (sonst nur Dateiname und Betreff)</label></p>
    <p class="hint" style="margin-bottom:0">Beide Ordner liegen im Standard-Archiv, relativ zu
    dessen Wurzel. Beispiel fuer den Dateinamen:
    <code>2026-03-01_lieferant_example.com_Rechnung.pdf</code>.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Gesperrte Dateitypen</h2>
    <div class="field">
      <label for="blocked_extensions">Endungen, die immer in die Quarantaene gehen</label>
      <input id="blocked_extensions" name="blocked_extensions" type="text" style="max-width:100%"
             value="{{ blocked }}">
    </div>
    <p class="hint" style="margin-bottom:0">Gilt auch, wenn ein Stichwort passt und auch fuer
    Abholordner - so kann &bdquo;Rechnung.exe&ldquo; nie im Rechnungsordner landen. Gedruckt
    wird so etwas nie. Komma-, Semikolon- oder Leerzeichen-getrennt, ohne Punkt.
    <strong>Leer heisst: keine Pruefung.</strong></p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Abruf und Grenzwerte</h2>
    <div class="row">
      <div class="field">
        <label for="poll_interval">Abrufintervall (Sekunden)</label>
        <input id="poll_interval" name="poll_interval" type="number" value="{{ o.poll_interval }}"
               min="{{ limits.poll_interval[0] }}" max="{{ limits.poll_interval[1] }}">
      </div>
      <div class="field">
        <label for="max_attachment_size_mb">Max. Groesse je Anhang (MB)</label>
        <input id="max_attachment_size_mb" name="max_attachment_size_mb" type="number"
               value="{{ o.max_attachment_size_mb }}" min="1">
      </div>
      <div class="field">
        <label for="max_message_size_mb">Max. Groesse je Mail (MB)</label>
        <input id="max_message_size_mb" name="max_message_size_mb" type="number"
               value="{{ o.max_message_size_mb }}" min="1">
      </div>
      <div class="field">
        <label for="max_attachments_per_message">Max. Anhaenge je Mail</label>
        <input id="max_attachments_per_message" name="max_attachments_per_message" type="number"
               value="{{ o.max_attachments_per_message }}" min="1">
      </div>
      <div class="field">
        <label for="pickup_min_age">Abholordner: fertig nach (Sekunden)</label>
        <input id="pickup_min_age" name="pickup_min_age" type="number"
               value="{{ o.pickup_min_age }}" min="0">
      </div>
    </div>
    <p class="hint" style="margin-bottom:0">Das Intervall gilt im Polling-Modus und als
    Erneuerung bei IDLE. Mails ueber der Maximalgroesse werden gar nicht erst geladen,
    sondern nur als gelesen markiert (und ggf. in den Ordner fuer zu grosse Mails
    verschoben). Eine Datei im Abholordner wird erst angefasst, wenn sie so lange
    unveraendert ist - ein Scan, der noch geschrieben wird, bleibt liegen.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Drucken</h2>
    <p style="margin-top:0"><label><input type="checkbox" name="printing_enabled" value="1"
      {% if o.printing_enabled %}checked{% endif %}> Drucken erlaubt</label></p>
    <div class="row">
      <div class="field">
        <label for="printable_extensions">Druckbare Dateitypen</label>
        <input id="printable_extensions" name="printable_extensions" type="text"
               style="max-width:100%" value="{{ printable }}">
      </div>
      <div class="field">
        <label for="print_timeout">Zeitgrenze je Druckauftrag (Sekunden)</label>
        <input id="print_timeout" name="print_timeout" type="number"
               value="{{ o.print_timeout }}" min="5">
      </div>
    </div>
    <p class="hint" style="margin-bottom:0">Ausgeschaltet ist das der Notschalter: es wird
    nichts gedruckt, egal was bei Postfaechern, Zuordnungen und Adressen steht. Nur die
    genannten Formate gehen an einen Drucker (leer = Standardliste) - ein .docx ohne
    Konverter kaeme als Zeichensalat heraus.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Testmodus</h2>
    <p style="margin-top:0"><label><input type="checkbox" name="dry_run" value="1"
      {% if o.dry_run %}checked{% endif %}> Nur protokollieren - nichts ablegen, nichts
      drucken, keine Mail als gelesen markieren</label></p>
    <p class="hint" style="margin-bottom:0">Zum Ausprobieren neuer Zuordnungen: im
    Container-Log steht dann, was passiert waere. Achtung: im Testmodus wird dieselbe
    Mail bei jedem Durchlauf erneut geprueft.</p>
  </div>

  <button type="submit">Einstellungen speichern</button>
  <span class="hint">&nbsp;Wirkt sofort, ohne Neustart.</span>
</form>
"""

PASSWORD_BODY = """
<div class="card">
  <h2 style="margin-top:0">Passwort aendern</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field" style="margin-bottom:.6rem">
      <label for="current">Aktuelles Passwort</label>
      <input id="current" name="current" type="password" autocomplete="current-password" required>
    </div>
    <div class="field" style="margin-bottom:.6rem">
      <label for="new">Neues Passwort (mindestens {{ min_length }} Zeichen)</label>
      <input id="new" name="new" type="password" autocomplete="new-password" required>
    </div>
    <div class="field" style="margin-bottom:.9rem">
      <label for="confirm">Neues Passwort wiederholen</label>
      <input id="confirm" name="confirm" type="password" autocomplete="new-password" required>
    </div>
    <button type="submit">Passwort aendern</button>
  </form>
  <p class="hint">Nach der Aenderung werden alle anderen angemeldeten Sitzungen
  abgemeldet. Passwort vergessen? Auf dem Server:
  <code>docker compose exec mail2nas python -m mail2nas.cli reset-password</code></p>
</div>
"""


def test_imap(account, timeout: int = 20) -> int:
    """Log in, open the folder, count unseen mail. Raises on any failure."""
    from imapclient import IMAPClient

    client = IMAPClient(account.host, port=account.port, ssl=account.ssl, timeout=timeout)
    try:
        client.login(account.user, account.password)
        client.select_folder(account.folder, readonly=True)
        return len(client.search(["UNSEEN"]))
    finally:
        try:
            client.logout()
        except Exception:  # noqa: BLE001 - the answer is already known
            pass


def create_app(runtime) -> Flask:
    """Build the web UI on top of a Runtime (config, storage, settings, accounts)."""
    config, settings = runtime.config, runtime.settings

    def storage():
        """The default archive, or None - looked up per request, it is editable."""
        return runtime.storage
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=_secret_key(settings),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=config.web_cookie_secure,
        PERMANENT_SESSION_LIFETIME=timedelta(hours=SESSION_HOURS),
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    throttle = LoginThrottle()

    # --- helpers ---------------------------------------------------------

    def session_version() -> str:
        return settings.get(SETTING_SESSION_VERSION) or "1"

    def logged_in() -> bool:
        return session.get("auth_version") == session_version()

    def csrf_token() -> str:
        token = session.get("csrf")
        if not token:
            token = secrets.token_urlsafe(32)
            session["csrf"] = token
        return token

    def require_csrf() -> None:
        sent = request.form.get("csrf_token", "")
        expected = session.get("csrf", "")
        if not expected or not secrets.compare_digest(sent, expected):
            abort(400, "Ungueltiges oder abgelaufenes Formular - bitte neu laden.")

    def render(body_template: str, title: str, **context):
        # Markup, not str: the inner template is ours and already escaped its
        # own values, so it must be inserted as markup rather than escaped a
        # second time. Everything user-supplied went through the inner render.
        body = Markup(render_template_string(body_template, csrf_token=csrf_token(), **context))
        return render_template_string(
            BASE_TEMPLATE,
            title=title,
            body=body,
            logged_in=logged_in(),
            setup_hint=_setup_hint() if request.endpoint != "overview_page" else "",
            csrf_token=csrf_token(),
            messages=get_flashed_messages(with_categories=True),
        )

    def login_required(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not logged_in():
                return redirect(url_for("login"))
            return view(*args, **kwargs)

        return wrapper

    @app.after_request
    def security_headers(response):
        # No scripts, no external resources - so the policy can be strict.
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
        )
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    # --- routes ----------------------------------------------------------

    @app.get("/healthz")
    def healthz():
        return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}

    @app.get("/")
    def index():
        return redirect(url_for("overview_page") if logged_in() else url_for("login"))

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if logged_in():
            return redirect(url_for("overview_page"))

        if request.method == "POST":
            require_csrf()
            client = request.remote_addr or "unknown"
            blocked = throttle.seconds_blocked(client)
            if blocked:
                flash(f"Zu viele Fehlversuche. Bitte {blocked} Sekunden warten.", "error")
                return render(LOGIN_BODY, "Anmelden"), 429

            stored_hash = settings.get(SETTING_PASSWORD_HASH) or ""
            if stored_hash and check_password_hash(stored_hash, request.form.get("password", "")):
                throttle.reset(client)
                # New session id material on login, so a token someone else
                # obtained before does not stay valid.
                session.clear()
                session.permanent = True
                session["auth_version"] = session_version()
                logger.info("Web UI: successful login from %s", client)
                return redirect(url_for("overview_page"))

            throttle.record_failure(client)
            logger.warning("Web UI: failed login from %s", client)
            flash("Falsches Passwort.", "error")
            return render(LOGIN_BODY, "Anmelden"), 401

        return render(LOGIN_BODY, "Anmelden")

    @app.post("/logout")
    def logout():
        require_csrf()
        session.clear()
        flash("Abgemeldet.", "ok")
        return redirect(url_for("login"))

    def _setup_hint() -> str:
        """One line on every page while something essential is missing."""
        if runtime.default_archive() is None:
            return "Noch kein Archiv eingerichtet - es wird nichts abgeholt oder abgelegt."
        if runtime.status.archive.ok is False:
            return "Das Standard-Archiv ist nicht bereit: " + runtime.status.archive.detail
        if not runtime.accounts.enabled() and not (runtime.pickups and runtime.pickups.enabled()):
            return "Noch kein aktives Postfach - es wird keine Mail abgeholt."
        return ""

    def _changed() -> None:
        """Tell the supervisor to look at the configuration now, not in 5 s."""
        runtime.changed.set()

    def _printers() -> list:
        """The printers offered in the dropdowns, or none if printing is off."""
        if runtime.printers is None or not runtime.options.printing_enabled:
            return []
        return runtime.printers.all()

    def _print_choice(value: str) -> tuple[bool, str]:
        """Read the "Drucken" dropdown: off, mailbox printer, or a named one."""
        value = (value or "").strip()
        if not value:
            return False, ""
        if value == "account":
            return True, ""
        if value not in {printer.key for printer in _printers()}:
            raise MappingError("Diesen Drucker gibt es nicht.")
        return True, value

    def _rules() -> list[Rule]:
        return runtime.rule_store.load()

    def _save(rules: list[Rule]) -> None:
        runtime.mapping.save(rules)

    def _index(rules: list[Rule]) -> int:
        try:
            index = int(request.form.get("index", ""))
        except ValueError:
            raise MappingError("Diese Zuordnung gibt es nicht mehr.") from None
        if not 0 <= index < len(rules):
            raise MappingError("Diese Zuordnung gibt es nicht mehr.")
        return index

    @app.get("/mapping")
    @login_required
    def mapping_page():
        try:
            rules = _rules()
        except MappingError as exc:
            rules = []
            flash(str(exc), "error")

        folders, storage_ok = [], False
        if storage() is not None:
            try:
                folders = storage().list_folders()
                storage_ok = True
            except Exception as exc:  # noqa: BLE001 - the share may be unreachable right now
                logger.warning("Web UI: could not list folders (%s)", exc)
                flash(f"Ordnerliste konnte nicht geladen werden: {exc}", "error")

        def folder_options(current: str) -> list[str]:
            # A rule may point at a folder that does not exist yet (it is
            # created on the first attachment), so keep it selectable.
            return sorted({*folders, current}) if current else folders

        accounts = runtime.accounts.all()
        printers = _printers()
        return render(
            MAPPING_BODY,
            "Zuordnungen",
            rules=rules,
            folders=folders,
            folder_options=folder_options,
            accounts=accounts,
            account_keys=[account.key for account in accounts] + [ALL_ACCOUNTS],
            printers=printers,
            printer_keys=[printer.key for printer in printers],
            **_archive_context(),
            storage_ok=storage_ok,
            migration_note=settings.get(SETTING_RULES_NOTE) or "",
            fallback_folder=runtime.options.fallback_folder,
            quarantine_folder=runtime.options.quarantine_folder,
        )

    @app.post("/mapping/note/dismiss")
    @login_required
    def dismiss_migration_note():
        require_csrf()
        settings.set(SETTING_RULES_NOTE, "")
        return redirect(url_for("mapping_page"))

    @app.get("/mapping/export")
    @login_required
    def export_rules():
        stamp = datetime.now().strftime("%Y-%m-%d")
        body = (
            f"# mail2nas - Zuordnungen, exportiert am {stamp}\n"
            "# Import: Weboberflaeche -> Zuordnungen -> Sichern und uebertragen\n"
            + dump_rules(_rules())
        )
        return body, 200, {
            "Content-Type": "application/x-yaml; charset=utf-8",
            "Content-Disposition": f'attachment; filename="mail2nas-mapping-{stamp}.yaml"',
        }

    @app.post("/mapping/import")
    @login_required
    def import_rules():
        require_csrf()
        upload = request.files.get("rules_file")
        try:
            if upload is None or not upload.filename:
                raise MappingError("Bitte eine Datei auswaehlen.")
            try:
                text = upload.read().decode("utf-8-sig")
            except UnicodeDecodeError:
                raise MappingError("Die Datei ist kein UTF-8-Text.") from None
            imported = rules_from_yaml(text)
            replace_all = request.form.get("mode") == "replace"
            rules = [] if replace_all else _rules()
            added = skipped = 0
            for rule in imported:
                try:
                    keyword = validate_keyword(rule.keyword, rules)
                except MappingError:
                    skipped += 1
                    continue
                folder = validate_folder(rule.folder)
                known = {a.key for a in runtime.accounts.all()}
                account = rule.account if rule.account in known else ALL_ACCOUNTS
                printers = {p.key for p in (runtime.printers.all() if runtime.printers else [])}
                archives = {a.key for a in _archives()}
                rules.append(
                    Rule.create(
                        keyword,
                        folder,
                        account,
                        rule.print_attachments,
                        rule.printer if rule.printer in printers else "",
                        rule.archive if rule.archive in archives else "",
                    )
                )
                added += 1
            _save(rules)
        except MappingError as exc:
            flash(f"Import abgebrochen: {exc}", "error")
        else:
            logger.info("Web UI: imported %d rule(s), skipped %d", added, skipped)
            flash(
                f"{added} Zuordnung(en) importiert"
                + (f", {skipped} uebersprungen (Stichwort gab es schon)" if skipped else "")
                + ". Postfaecher, Drucker und Archive, die es hier nicht gibt, wurden auf "
                "den Standard gesetzt.",
                "ok",
            )
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/add")
    @login_required
    def add_rule():
        require_csrf()
        new_folder = request.form.get("new_folder", "").strip()
        chosen = new_folder or request.form.get("folder", "")
        try:
            rules = _rules()
            keyword = validate_keyword(request.form.get("keyword", ""), rules)
            folder = validate_folder(chosen)
            account = _account_choice(request.form.get("account", ALL_ACCOUNTS))
            printing, printer = _print_choice(request.form.get("printer", ""))
            archive = _archive_choice(request.form.get("archive", ""))
            if new_folder:
                try:
                    _archive_storage(archive).create_folder(folder)
                except Exception as exc:  # noqa: BLE001 - the rule is still worth saving
                    flash(f"Ordner konnte noch nicht angelegt werden ({exc}) - das passiert "
                          "beim ersten Anhang.", "error")
            rules.append(Rule.create(keyword, folder, account, printing, printer, archive))
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001 - surface storage failures in the UI
            logger.exception("Web UI: could not add rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: added mapping %r -> %r", keyword, folder)
            flash(f"{keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    def _account_choice(value: str) -> str:
        value = (value or ALL_ACCOUNTS).strip()
        if value == ALL_ACCOUNTS:
            return ALL_ACCOUNTS
        if value not in {account.key for account in runtime.accounts.all()}:
            raise MappingError("Dieses Postfach gibt es nicht.")
        return value

    @app.post("/mapping/update")
    @login_required
    def update_rule():
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            rule = rules[index]
            folder = validate_folder(request.form.get("folder", ""))
            account = _account_choice(request.form.get("account", rule.account))
            # The print controls are only rendered when a printer exists, so
            # their absence means "leave as is" rather than "switch off".
            if request.form.get("print_fields"):
                printing, printer = _print_choice(request.form.get("printer", ""))
            else:
                printing, printer = rule.print_attachments, rule.printer
            # Same for the archive: the dropdown only exists once there is
            # more than one archive to choose from.
            archive = (
                _archive_choice(request.form.get("archive", ""))
                if request.form.get("archive_fields")
                else rule.archive
            )
            updated = Rule.create(rule.keyword, folder, account, printing, printer, archive)
            rules[index] = set_archive(
                set_printing(set_account(updated, account), printing, printer), archive
            )
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not update rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: changed mapping %r -> %r", rule.keyword, folder)
            flash(f"{rule.keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/delete")
    @login_required
    def delete_rule():
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            removed = rules.pop(index)
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not delete rule")
            flash(f"Loeschen fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: deleted mapping %r", removed.keyword)
            flash(f"{removed.keyword} geloescht. Der Ordner selbst bleibt bestehen.", "ok")
        return redirect(url_for("mapping_page"))

    def _reorder(offset: int):
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            _save(move_rule(rules, index, offset))
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not reorder rules")
            flash(f"Verschieben fehlgeschlagen: {exc}", "error")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/up")
    @login_required
    def move_rule_up():
        return _reorder(-1)

    @app.post("/mapping/down")
    @login_required
    def move_rule_down():
        return _reorder(1)

    # --- configuration ---------------------------------------------------

    @app.get("/config")
    @login_required
    def config_page():
        return render(
            CONFIG_BODY,
            "Konfiguration",
            accounts=runtime.accounts.all(),
            printers=_printers(),
            address_rules=_address_rules(),
            archives=_archives(),
            pickups=_pickup_rows(),
            pickup_interval=PICKUP_INTERVAL,
            printing_enabled=runtime.options.printing_enabled,
        )

    # --- general settings ----------------------------------------------------

    @app.route("/settings", methods=["GET", "POST"])
    @login_required
    def settings_page():
        options = runtime.options
        if request.method == "POST":
            require_csrf()
            try:
                new = validate_options(request.form, options)
            except OptionsError as exc:
                flash(str(exc), "error")
            else:
                runtime.set_options(new)
                logger.info("Web UI: settings saved")
                if not new.blocked_extensions:
                    flash("Gespeichert. Achtung: ohne gesperrte Dateiendungen wird nichts mehr "
                          "in die Quarantaene verschoben.", "error")
                elif new.dry_run and not options.dry_run:
                    flash("Gespeichert. Der Testmodus ist jetzt an - es wird nichts abgelegt.",
                          "error")
                else:
                    flash("Einstellungen gespeichert.", "ok")
                return redirect(url_for("settings_page"))
        return render(
            SETTINGS_BODY,
            "Einstellungen",
            o=options,
            prefixes=FILENAME_PREFIXES,
            limits=LIMITS,
            blocked=", ".join(sorted(options.blocked_extensions)),
            printable=", ".join(sorted(options.printable_extensions)),
        )

    # --- overview --------------------------------------------------------------

    def _when(timestamp) -> str:
        if not timestamp:
            return ""
        return datetime.fromtimestamp(timestamp).strftime("%d.%m. %H:%M:%S")

    @app.get("/overview")
    @login_required
    def overview_page():
        archives = _archives()
        accounts = runtime.accounts.all()
        rules = runtime.rule_store.count()
        printers = runtime.printers.all() if runtime.printers else []
        steps = [
            SimpleNamespace(
                title="Archiv einrichten",
                hint="wohin abgelegt wird - SMB-Freigabe auf dem NAS, mit Verbindungstest",
                url=url_for("new_archive") if not archives else url_for(
                    "edit_archive", archive_id=archives[0].id),
                done=bool(archives) and runtime.status.archive.ok is not False,
            ),
            SimpleNamespace(
                title="Postfach anlegen",
                hint="woher die Mails kommen (IMAP), mit Anmeldetest",
                url=url_for("new_account"),
                done=bool(accounts),
            ),
            SimpleNamespace(
                title="Zuordnungen anlegen",
                hint="welches Stichwort in welchen Ordner - oder eine alte mapping.yaml importieren",
                url=url_for("mapping_page"),
                done=rules > 0,
            ),
            SimpleNamespace(
                title="Drucker (optional)",
                hint="einmal anlegen, dann je Postfach, Zuordnung oder Adresse auswaehlen",
                url=url_for("new_printer") if not printers else url_for("config_page"),
                done=bool(printers),
            ),
        ]
        board = runtime.status.workers()
        names = {f"account:{a.id}": a.name for a in accounts}
        workers = []
        for key, row in sorted(board.items()):
            if key.startswith("account:") and key not in names:
                continue
            workers.append(SimpleNamespace(
                label=names.get(key, "Abholordner" if key == "pickups" else row.label),
                state=row.state,
                detail=row.detail,
                processed=row.processed,
                last_ok=_when(row.last_ok),
                last_error=row.last_error,
                last_error_at=_when(row.last_error_at),
            ))
        supervisor = getattr(runtime, "supervisor", None)
        problems = list(supervisor.pickup_problems().values()) if supervisor else []
        return render(
            OVERVIEW_BODY,
            "Uebersicht",
            steps=steps,
            steps_open=not all(step.done for step in steps[:3]),
            archive_status=runtime.status.archive,
            workers=workers,
            pickup_problems=problems,
            ready=runtime.status.archive.ok,
            dry_run=runtime.options.dry_run,
            initial_password=read_initial_password(config.data_dir) is not None,
            now=_when(time.time()),
            started=_when(runtime.status.started_at),
            counts=SimpleNamespace(
                accounts=len(accounts),
                archives=len(archives),
                rules=rules,
                printers=len(printers),
                addresses=len(runtime.addresses.all()) if runtime.addresses else 0,
                pickups=len(runtime.pickups.all()) if runtime.pickups else 0,
            ),
        )

    def _account_form(account=None):
        """Read the account form, keeping the stored password if left empty."""
        password = request.form.get("password", "")
        if not password and account is not None:
            password = account.password
        try:
            port = int(request.form.get("port", "993").strip())
        except ValueError:
            raise MappingError("Der Port muss eine Zahl sein.") from None
        if not 1 <= port <= 65535:
            raise MappingError("Der Port muss zwischen 1 und 65535 liegen.")
        if not request.form.get("host", "").strip():
            raise MappingError("Bitte einen IMAP-Server angeben.")
        if not request.form.get("user", "").strip():
            raise MappingError("Bitte einen Benutzernamen angeben.")
        if not password:
            raise MappingError("Bitte ein Passwort angeben.")
        if request.form.get("print_fields"):
            printer = request.form.get("printer", "").strip()
            if printer and printer not in {p.key for p in _printers()}:
                raise MappingError("Diesen Drucker gibt es nicht.")
            printing = {
                "print_attachments": bool(request.form.get("print_attachments")),
                "printer": printer,
                "archive_attachments": bool(request.form.get("archive_attachments")),
            }
        elif account is not None:
            printing = {
                "print_attachments": account.print_attachments,
                "printer": account.printer,
                "archive_attachments": account.archive_attachments,
            }
        else:
            printing = {}
        return {
            **printing,
            "name": request.form.get("name", ""),
            "host": request.form.get("host", ""),
            "port": port,
            "ssl": bool(request.form.get("ssl")),
            "user": request.form.get("user", ""),
            "password": password,
            "folder": request.form.get("folder", "INBOX"),
            "mode": request.form.get("mode", "poll"),
            "processed_folder": request.form.get("processed_folder", ""),
            "oversized_folder": request.form.get("oversized_folder", ""),
            "enabled": bool(request.form.get("enabled")),
        }

    @app.route("/config/accounts/new", methods=["GET", "POST"])
    @login_required
    def new_account():
        if request.method == "POST":
            require_csrf()
            try:
                runtime.accounts.add(**_account_form())
            except MappingError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: added IMAP account %r", request.form.get("host"))
                flash("Postfach angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(ACCOUNT_BODY, "Postfach", account=None, **_printer_context())

    @app.route("/config/accounts/<int:account_id>", methods=["GET", "POST"])
    @login_required
    def edit_account(account_id: int):
        account = runtime.accounts.get(account_id)
        if account is None:
            flash("Dieses Postfach gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                runtime.accounts.update(account_id, **_account_form(account))
            except MappingError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: updated IMAP account %s", account_id)
                flash("Postfach gespeichert.", "ok")
                return redirect(url_for("config_page"))
            account = runtime.accounts.get(account_id)
        return render(ACCOUNT_BODY, "Postfach", account=account, **_printer_context())

    @app.post("/config/accounts/<int:account_id>/delete")
    @login_required
    def delete_account(account_id: int):
        require_csrf()
        runtime.accounts.delete(account_id)
        _changed()
        logger.info("Web UI: deleted IMAP account %s", account_id)
        flash("Postfach geloescht.", "ok")
        return redirect(url_for("config_page"))

    @app.post("/config/accounts/<int:account_id>/test")
    @login_required
    def test_account(account_id: int):
        require_csrf()
        account = runtime.accounts.get(account_id)
        if account is None:
            flash("Dieses Postfach gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            unseen = test_imap(account)
        except Exception as exc:  # noqa: BLE001 - report every failure in the UI
            logger.info("Web UI: IMAP test for %s failed: %s", account.host, exc)
            flash(f"Anmeldung fehlgeschlagen: {exc}", "error")
        else:
            flash(
                f"Angemeldet, Ordner {account.folder} geoeffnet - "
                f"{unseen} ungelesene Mail(s) warten dort.",
                "ok",
            )
        return redirect(url_for("edit_account", account_id=account_id))

    # --- archives -------------------------------------------------------------

    def _archives() -> list:
        """The archives offered in the dropdowns; empty means "just the one"."""
        if runtime.archives is None:
            return []
        return runtime.archives.all()

    def _archive_context() -> dict:
        archives = _archives()
        return {"archives": archives, "archive_keys": [a.key for a in archives]}

    def _archive_choice(value: str, fallback: str = "") -> str:
        """Read an archive dropdown, refusing one that no longer exists."""
        value = (value or "").strip()
        if not value:
            return ""
        if value not in {archive.key for archive in _archives()}:
            raise MappingError("Dieses Archiv gibt es nicht.")
        return value

    def _archive_storage(key: str):
        return runtime.storages.get(key) if runtime.storages else storage()

    def _require_archives():
        if runtime.archives is None:
            abort(404)
        return runtime.archives

    def _archive_form() -> dict:
        backend = request.form.get("backend", "smb").strip().lower()
        return {
            "name": request.form.get("name", ""),
            "backend": backend,
            "host": request.form.get("host", ""),
            "share": request.form.get("share", ""),
            "user": request.form.get("user", ""),
            "password": request.form.get("password", ""),
            "domain": request.form.get("domain", ""),
            "port": request.form.get("port", "445").strip() or "445",
            "root": request.form.get("root", ""),
            "encrypt": bool(request.form.get("encrypt")),
            "path": request.form.get("path", ""),
            "enabled": bool(request.form.get("enabled")),
        }

    @app.route("/config/archives/new", methods=["GET", "POST"])
    @login_required
    def new_archive():
        archives = _require_archives()
        if request.method == "POST":
            require_csrf()
            try:
                archives.add(**_archive_form())
            except ArchiveError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: added archive %r", request.form.get("name"))
                flash("Archiv angelegt. Mit „Verbindung testen\" pruefen, ob es erreichbar ist.", "ok")
                return redirect(url_for("config_page"))
        return render(ARCHIVE_BODY, "Archiv", archive=None)

    @app.route("/config/archives/<int:archive_id>", methods=["GET", "POST"])
    @login_required
    def edit_archive(archive_id: int):
        archives = _require_archives()
        archive = archives.get(archive_id)
        if archive is None:
            flash("Dieses Archiv gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            fields = _archive_form()
            # An empty password field means "keep the stored one", like the
            # mailbox form - the page never shows the password back.
            if not fields["password"]:
                fields["password"] = archive.password
            try:
                archives.update(archive_id, **fields)
            except ArchiveError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated archive %s", archive_id)
                flash("Archiv gespeichert.", "ok")
                _changed()
                return redirect(url_for("config_page"))
            archive = archives.get(archive_id)
        return render(ARCHIVE_BODY, "Archiv", archive=archive)

    @app.post("/config/archives/<int:archive_id>/test")
    @login_required
    def test_archive(archive_id: int):
        require_csrf()
        archive = _require_archives().get(archive_id)
        if archive is None:
            flash("Dieses Archiv gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            archive.to_storage().check_writable()
        except SystemExit as exc:
            flash(f"Nicht erreichbar: {exc}", "error")
        except Exception as exc:  # noqa: BLE001 - report anything else too
            logger.exception("Web UI: archive test failed")
            flash(f"Nicht erreichbar: {exc}", "error")
        else:
            flash(f"{archive.location()} ist erreichbar und beschreibbar.", "ok")
        return redirect(url_for("edit_archive", archive_id=archive_id))

    @app.post("/config/archives/<int:archive_id>/delete")
    @login_required
    def delete_archive(archive_id: int):
        require_csrf()
        archives = _require_archives()
        if len(archives.all()) <= 1:
            flash("Das letzte Archiv kann nicht geloescht werden.", "error")
            return redirect(url_for("config_page"))
        archives.delete(archive_id)
        logger.info("Web UI: deleted archive %s", archive_id)
        _changed()
        flash(
            "Archiv geloescht. Zuordnungen, Zustelladressen und Abholordner, die darauf "
            "zeigten, nutzen jetzt das Standard-Archiv.",
            "ok",
        )
        return redirect(url_for("config_page"))

    # --- delivery addresses -------------------------------------------------

    def _require_addresses():
        """The address pages only exist when there is a store behind them."""
        if runtime.addresses is None:
            abort(404)
        return runtime.addresses

    def _address_rules() -> list:
        """The rules plus the label of the printer each one names, for the list."""
        if runtime.addresses is None:
            return []
        labels = {printer.key: printer.label() for printer in _printers()}
        archive_names = {archive.key: archive.name for archive in _archives()}
        rules = []
        for rule in runtime.addresses.all():
            rules.append(
                SimpleNamespace(
                    id=rule.id,
                    name=rule.name,
                    recipient=rule.recipient,
                    sender=rule.sender,
                    print_attachments=rule.print_attachments,
                    printer=rule.printer,
                    printer_label=labels.get(rule.printer, ""),
                    archive_attachments=rule.archive_attachments,
                    folder=rule.folder,
                    archive_label=archive_names.get(rule.archive, ""),
                    enabled=rule.enabled,
                )
            )
        return rules

    def _address_form() -> dict:
        return {
            "name": request.form.get("name", ""),
            "recipient": request.form.get("recipient", ""),
            "sender": request.form.get("sender", ""),
            "print_attachments": bool(request.form.get("print_attachments")),
            "printer": request.form.get("printer", ""),
            "archive_attachments": bool(request.form.get("archive_attachments")),
            "folder": request.form.get("folder", ""),
            "archive": request.form.get("archive", ""),
            "enabled": bool(request.form.get("enabled")),
        }

    @app.route("/config/addresses/new", methods=["GET", "POST"])
    @login_required
    def new_address():
        addresses = _require_addresses()
        if request.method == "POST":
            require_csrf()
            try:
                addresses.add(**_address_form())
            except AddressError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added address rule %r", request.form.get("recipient"))
                flash("Zustelladresse angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(
            ADDRESS_BODY, "Zustelladresse", entry=None, **_printer_context(), **_archive_context()
        )

    @app.route("/config/addresses/<int:address_id>", methods=["GET", "POST"])
    @login_required
    def edit_address(address_id: int):
        addresses = _require_addresses()
        entry = addresses.get(address_id)
        if entry is None:
            flash("Diese Zustelladresse gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                addresses.update(address_id, **_address_form())
            except AddressError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated address rule %s", address_id)
                flash("Zustelladresse gespeichert.", "ok")
                return redirect(url_for("config_page"))
            entry = addresses.get(address_id)
        return render(
            ADDRESS_BODY, "Zustelladresse", entry=entry, **_printer_context(), **_archive_context()
        )

    @app.post("/config/addresses/<int:address_id>/delete")
    @login_required
    def delete_address(address_id: int):
        require_csrf()
        _require_addresses().delete(address_id)
        logger.info("Web UI: deleted address rule %s", address_id)
        flash("Zustelladresse geloescht.", "ok")
        return redirect(url_for("config_page"))

    # --- pickup folders -------------------------------------------------------

    def _require_pickups():
        if runtime.pickups is None:
            abort(404)
        return runtime.pickups

    def _pickups() -> list:
        return runtime.pickups.all() if runtime.pickups is not None else []

    def _pickup_rows() -> list:
        """The pickup folders with the names of what they point at."""
        if runtime.pickups is None:
            return []
        archive_names = {archive.key: archive.name for archive in _archives()}
        printer_labels = {printer.key: printer.label() for printer in _printers()}
        rows = []
        for pickup in runtime.pickups.all():
            rows.append(
                SimpleNamespace(
                    id=pickup.id,
                    name=pickup.name,
                    folder=pickup.folder,
                    archive_label=archive_names.get(pickup.archive, ""),
                    target_folder=pickup.target_folder,
                    target_archive_label=archive_names.get(pickup.target_archive, ""),
                    print_attachments=pickup.print_attachments,
                    printer_label=printer_labels.get(pickup.printer, ""),
                    enabled=pickup.enabled,
                )
            )
        return rows

    def _pickup_form() -> dict:
        printing, printer = _print_choice(request.form.get("printer", ""))
        return {
            "name": request.form.get("name", ""),
            "archive": request.form.get("archive", ""),
            "folder": request.form.get("folder", ""),
            "target_archive": request.form.get("target_archive", ""),
            "target_folder": request.form.get("target_folder", ""),
            # "Drucker des Postfachs" makes no sense here - a folder has none.
            "print_attachments": bool(printer),
            "printer": printer,
            "enabled": bool(request.form.get("enabled")),
        }

    def _pickup_context() -> dict:
        return {
            **_archive_context(),
            **_printer_context(),
            "min_age": runtime.pickup_min_age,
        }

    @app.route("/config/pickups/new", methods=["GET", "POST"])
    @login_required
    def new_pickup():
        pickups = _require_pickups()
        if request.method == "POST":
            require_csrf()
            try:
                pickups.add(**_pickup_form())
            except PickupError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added pickup folder %r", request.form.get("folder"))
                flash("Abholordner angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(PICKUP_BODY, "Abholordner", pickup=None, **_pickup_context())

    @app.route("/config/pickups/<int:pickup_id>", methods=["GET", "POST"])
    @login_required
    def edit_pickup(pickup_id: int):
        pickups = _require_pickups()
        pickup = pickups.get(pickup_id)
        if pickup is None:
            flash("Diesen Abholordner gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                pickups.update(pickup_id, **_pickup_form())
            except PickupError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated pickup folder %s", pickup_id)
                flash("Abholordner gespeichert.", "ok")
                return redirect(url_for("config_page"))
            pickup = pickups.get(pickup_id)
        return render(PICKUP_BODY, "Abholordner", pickup=pickup, **_pickup_context())

    @app.post("/config/pickups/<int:pickup_id>/delete")
    @login_required
    def delete_pickup(pickup_id: int):
        require_csrf()
        _require_pickups().delete(pickup_id)
        logger.info("Web UI: deleted pickup folder %s", pickup_id)
        flash("Abholordner geloescht.", "ok")
        return redirect(url_for("config_page"))

    # --- printers ---------------------------------------------------------

    def _printer_context() -> dict:
        printers = _printers()
        return {"printers": printers, "printer_keys": [printer.key for printer in printers]}

    def _printer_form() -> dict:
        return {
            "name": request.form.get("name", ""),
            "destination": request.form.get("destination", ""),
            "server": request.form.get("server", ""),
            "options": request.form.get("options", ""),
            "copies": request.form.get("copies", "1").strip() or "1",
            "enabled": bool(request.form.get("enabled")),
        }

    def _require_printers():
        """The printer pages only exist when there is a store behind them."""
        if runtime.printers is None:
            abort(404)
        return runtime.printers

    @app.route("/config/printers/new", methods=["GET", "POST"])
    @login_required
    def new_printer():
        printers = _require_printers()
        if request.method == "POST":
            require_csrf()
            try:
                printers.add(**_printer_form())
            except PrinterError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added printer %r", request.form.get("destination"))
                flash("Drucker angelegt. Ein Testdruck zeigt, ob er erreichbar ist.", "ok")
                return redirect(url_for("config_page"))
        # A "Uebernehmen" link from the discovery page arrives as query
        # parameters; they only prefill the form, nothing is saved yet.
        suggestion = None
        if request.args.get("destination"):
            suggestion = SimpleNamespace(
                name=request.args.get("name", ""),
                destination=request.args.get("destination", ""),
                server=request.args.get("server", ""),
                options="",
                copies=1,
                enabled=True,
                id=None,
            )
        return render(PRINTER_BODY, "Drucker", printer=suggestion)

    @app.route("/config/printers/<int:printer_id>", methods=["GET", "POST"])
    @login_required
    def edit_printer(printer_id: int):
        printers = _require_printers()
        printer = printers.get(printer_id)
        if printer is None:
            flash("Diesen Drucker gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                printers.update(printer_id, **_printer_form())
            except PrinterError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated printer %s", printer_id)
                flash("Drucker gespeichert.", "ok")
                return redirect(url_for("config_page"))
            printer = printers.get(printer_id)
        return render(PRINTER_BODY, "Drucker", printer=printer)

    @app.post("/config/printers/<int:printer_id>/test")
    @login_required
    def test_printer(printer_id: int):
        require_csrf()
        printers = _require_printers()
        printer = printers.get(printer_id)
        if printer is None or runtime.printing is None:
            flash("Diesen Drucker gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            runtime.printing.spooler.print_test_page(printer)
        except PrintError as exc:
            flash(f"Testdruck fehlgeschlagen: {exc}", "error")
        except Exception as exc:  # noqa: BLE001 - surface anything else in the UI too
            logger.exception("Web UI: test print failed")
            flash(f"Testdruck fehlgeschlagen: {exc}", "error")
        else:
            flash("Testseite an die Warteschlange uebergeben.", "ok")
        return redirect(url_for("edit_printer", printer_id=printer_id))

    @app.route("/config/printers/discover", methods=["GET", "POST"])
    @login_required
    def discover_printers():
        _require_printers()
        # Default to the server the printers already use: on a NAS box that is
        # usually the one CUPS runs on, and typing it again is pointless.
        configured = next((p.server for p in _printers() if p.server), "")
        server = request.form.get("server", configured).strip()
        found: list = []
        problems: list[str] = []
        searched = request.method == "POST"
        if searched:
            require_csrf()
            try:
                found, problems = discover(server, lpstat_binary=config.lpstat_binary)
            except Exception as exc:  # noqa: BLE001 - the page reports, never 500s
                logger.exception("Web UI: printer discovery failed")
                problems = [f"Suche fehlgeschlagen: {exc}"]
        return render(
            DISCOVERY_BODY,
            "Drucker suchen",
            server=server,
            found=found,
            problems=problems,
            searched=searched,
        )

    @app.post("/config/printers/<int:printer_id>/delete")
    @login_required
    def delete_printer(printer_id: int):
        require_csrf()
        _require_printers().delete(printer_id)
        # An address rule pointing at a deleted queue would keep asking for a
        # printer that no longer exists; blank it so it falls back to the
        # mailbox printer instead of silently printing nothing.
        unpinned = runtime.addresses.clear_printer(str(printer_id)) if runtime.addresses else 0
        if runtime.pickups is not None:
            unpinned += runtime.pickups.clear_printer(str(printer_id))
        logger.info("Web UI: deleted printer %s", printer_id)
        flash(
            "Drucker geloescht. Postfaecher und Zuordnungen, die auf ihn zeigten, "
            "drucken nicht mehr."
            + (
                f" {unpinned} Zustelladresse(n) nutzen jetzt den Drucker des Postfachs."
                if unpinned
                else ""
            ),
            "ok",
        )
        return redirect(url_for("config_page"))

    @app.route("/password", methods=["GET", "POST"])
    @login_required
    def password_page():
        if request.method == "POST":
            require_csrf()
            current = request.form.get("current", "")
            new = request.form.get("new", "")
            confirm = request.form.get("confirm", "")
            stored_hash = settings.get(SETTING_PASSWORD_HASH) or ""

            if not check_password_hash(stored_hash, current):
                flash("Aktuelles Passwort stimmt nicht.", "error")
            elif len(new) < MIN_PASSWORD_LENGTH:
                flash(f"Das neue Passwort braucht mindestens {MIN_PASSWORD_LENGTH} Zeichen.", "error")
            elif new != confirm:
                flash("Die beiden neuen Passwoerter stimmen nicht ueberein.", "error")
            elif new == current:
                flash("Das neue Passwort ist mit dem alten identisch.", "error")
            else:
                # Invalidates every session, including this one; this browser
                # is logged back in below - so a stolen cookie stops working.
                set_password(settings, new, config.data_dir)
                session.clear()
                session.permanent = True
                session["auth_version"] = session_version()
                logger.info("Web UI: password changed")
                flash("Passwort geaendert.", "ok")
                return redirect(url_for("overview_page"))

        return render(PASSWORD_BODY, "Passwort", min_length=MIN_PASSWORD_LENGTH)

    return app


def _secret_key(settings) -> str:
    """Persist the cookie signing key, so restarts do not log everyone out."""
    key = settings.get(SETTING_SECRET_KEY)
    if not key:
        key = secrets.token_urlsafe(48)
        settings.set(SETTING_SECRET_KEY, key)
    return key


INITIAL_PASSWORD_FILE = "initial-password.txt"
# No 0/O, 1/l/I: the password is read off a terminal and typed into a browser.
_PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"


def generate_password() -> str:
    """A random password that survives being read aloud: 4 x 4 characters."""
    chars = "".join(secrets.choice(_PASSWORD_ALPHABET) for _ in range(16))
    return "-".join(chars[i : i + 4] for i in range(0, 16, 4))


def initial_password_path(data_dir: str | None) -> str | None:
    return os.path.join(data_dir, INITIAL_PASSWORD_FILE) if data_dir else None


def _write_initial_password(data_dir: str | None, password: str) -> None:
    path = initial_password_path(data_dir)
    if not path:
        return
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(password + "\n")
        os.chmod(path, 0o600)
    except OSError as exc:
        logger.warning("Could not write %s (%s) - the password is only in this log", path, exc)


def read_initial_password(data_dir: str | None) -> str | None:
    path = initial_password_path(data_dir)
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def set_password(settings, new_password: str, data_dir: str | None = None) -> None:
    """Store a new password and log every session out.

    The generated first password is removed from disk at the same time: once
    somebody chose their own, a readable copy of the old one has no purpose.
    """
    settings.set(SETTING_PASSWORD_HASH, generate_password_hash(new_password))
    version = settings.get(SETTING_SESSION_VERSION) or "1"
    settings.set(SETTING_SESSION_VERSION, str(int(version) + 1))
    path = initial_password_path(data_dir)
    if path:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            logger.warning("Could not remove %s (%s)", path, exc)


def ensure_password(settings, initial_password: str = "", data_dir: str | None = None) -> str | None:
    """Make sure the UI has a password. Returns it if one was generated.

    Order of preference: a stored hash (the user's own choice, or the first
    password from an earlier start), then WEB_PASSWORD from an older `.env`,
    then a random one. The random one is written to `initial-password.txt`
    next to the database (mode 0600) - that is where the installer reads it
    from to show it - and logged once, so a plain `docker compose logs`
    finds it too. Either way it is meant to be changed after the first login.
    """
    if settings.get(SETTING_PASSWORD_HASH):
        return None
    if initial_password and len(initial_password) >= MIN_PASSWORD_LENGTH:
        settings.set(SETTING_PASSWORD_HASH, generate_password_hash(initial_password))
        logger.info("Web UI: initial password taken from WEB_PASSWORD")
        return None
    if initial_password:
        logger.error(
            "WEB_PASSWORD is shorter than %d characters - generating a random one instead",
            MIN_PASSWORD_LENGTH,
        )

    password = generate_password()
    settings.set(SETTING_PASSWORD_HASH, generate_password_hash(password))
    _write_initial_password(data_dir, password)
    logger.warning(
        "Web UI: no password was set, generated one: %s  (also in %s - "
        "please change it after the first login)",
        password,
        initial_password_path(data_dir) or "nowhere else",
    )
    return password


def serve(runtime) -> threading.Thread:
    """Bind the port and serve the UI on a daemon thread.

    Binding happens here, in the caller's thread, so a port clash is a startup
    error rather than a stack trace that scrolls past unnoticed while the
    archiver keeps running without a UI.
    """
    from waitress import create_server

    config = runtime.config
    ensure_password(runtime.settings, config.web_password, config.data_dir)
    app = create_app(runtime)
    try:
        server = create_server(app, host=config.web_host, port=config.web_port, threads=4)
    except OSError as exc:
        raise SystemExit(
            f"Web UI cannot listen on {config.web_host}:{config.web_port}: {exc}"
        ) from exc

    thread = threading.Thread(target=server.run, name="mail2nas-web", daemon=True)
    thread.start()
    logger.info("Web UI listening on http://%s:%d", config.web_host, config.web_port)
    return thread
MAIL2NAS_EOF

# --- mail2nas/main.py ---
cat > mail2nas/main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import sys
import threading
import time

from .accounts import AccountStore
from .addresses import AddressStore
from .archiver import Archiver
from .archives import ArchiveStore
from .config import Config
from .legacy import LegacyEnv
from .mapping import RuleStore
from .migrate import migrate_rule_file, rules_settled, seed_from_legacy
from .pickups import PICKUP_INTERVAL, PickupStore
from .printers import PrinterStore
from .runtime import Runtime
from .scanning import PickupRunner
from .state import ProcessedStore, SettingsStore

logger = logging.getLogger("mail2nas")

# How often the supervisor notices that accounts were added, changed or
# removed in the web UI. Short enough to feel immediate, long enough to be
# free.
SUPERVISOR_INTERVAL = 5
# How often an archive that failed its write test is tried again.
ARCHIVE_RETRY = 60
# IMAP IDLE is waited on in short slices, so stopping a worker (because its
# settings changed) takes a few seconds instead of up to a whole interval.
IDLE_SLICE = 5
# RFC 2177: re-issue IDLE before 29 minutes, or the server may drop us.
MAX_IDLE = 29 * 60


def build_runtime(config: Config, environ=None) -> Runtime:
    """Open the database, bring an older installation up to date, wire it up."""
    settings = SettingsStore(config.state_db_path)
    # Before anything is written: the file holds IMAP and SMB passwords.
    _protect_state_file(config.state_db_path)
    printers = PrinterStore(config.state_db_path)
    runtime = Runtime(
        config,
        settings,
        AccountStore(config.state_db_path),
        ProcessedStore(config.state_db_path),
        RuleStore(config.state_db_path),
        printers=printers,
        addresses=AddressStore(config.state_db_path),
        archives=ArchiveStore(config.state_db_path),
        pickups=PickupStore(config.state_db_path),
    )
    seed_from_legacy(runtime, LegacyEnv.from_environ(environ))
    return runtime


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    runtime = build_runtime(config)

    if os.environ.get("WEB_ENABLED", "").strip().lower() in ("0", "false", "no", "off"):
        # The web UI is the only place left to configure anything, so it
        # cannot be switched off any more. Say so instead of silently ignoring.
        logger.warning("WEB_ENABLED=false is ignored - the web UI is where mail2nas is configured")

    # Imported here so the modules above stay importable without Flask.
    from . import web

    web.serve(runtime)

    options = runtime.options
    logger.info(
        "Starting mail2nas: mailboxes=%d archives=%d rules=%d printers=%d addresses=%d "
        "pickups=%d dry_run=%s",
        len(runtime.accounts.enabled()),
        len(runtime.archives.enabled()),
        runtime.rule_store.count(),
        len(runtime.printers.enabled()) if options.printing_enabled else 0,
        len(runtime.addresses.enabled()),
        len(runtime.pickups.enabled()),
        options.dry_run,
    )

    supervisor = Supervisor(runtime)
    try:
        supervisor.run()
    finally:
        supervisor.stop_all()
        runtime.store.close()
        runtime.storages.close()


def _protect_state_file(path: str) -> None:
    """The state database holds passwords, so nobody else may read it."""
    try:
        if not os.path.exists(path):
            open(path, "a").close()
        os.chmod(path, 0o600)
    except OSError as exc:
        logger.warning("Could not restrict permissions on %s (%s)", path, exc)


class _Worker:
    """One IMAP account, watched on its own thread.

    A thread per account rather than one loop over all of them: IMAP IDLE
    blocks, so a single loop would leave every other mailbox waiting for the
    first one's timeout.
    """

    def __init__(self, runtime: Runtime, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self.key = f"account:{account.id}"
        self._runtime = runtime
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name=f"mail2nas-imap-{account.id}", daemon=True
        )

    def start(self) -> None:
        self._runtime.status.worker(self.key, self.account.name)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def _interval(self) -> int:
        return self._runtime.options.poll_interval

    def _run(self) -> None:
        runtime = self._runtime
        archiver = Archiver(
            lambda: runtime.options,
            runtime.mapping,
            runtime.store,
            runtime.storages,
            self.account,
            runtime.printing,
            runtime.addresses,
        )
        status = runtime.status
        label = f"{self.account.name} <{self.account.user}>"
        logger.info(
            "Account %s: watching %s on %s (%s mode)",
            label,
            self.account.folder,
            self.account.host,
            self.account.mode,
        )

        while not self._stop.is_set():
            status.set(self.key, "verbindet")
            try:
                client = archiver.connect()
            except Exception as exc:
                logger.exception(
                    "Account %s: IMAP connection failed, retrying in %ss", label, self._interval()
                )
                status.error(self.key, f"Verbindung fehlgeschlagen: {exc}")
                self._stop.wait(self._interval())
                continue

            try:
                if self.account.mode == "idle":
                    self._run_idle(archiver, client, label)
                else:
                    self._run_poll(archiver, client, label)
            except Exception as exc:
                logger.exception(
                    "Account %s: IMAP session failed, reconnecting in %ss", label, self._interval()
                )
                status.error(self.key, f"Sitzung abgebrochen: {exc}")
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            self._stop.wait(self._interval())

        status.set(self.key, "gestoppt")
        logger.info("Account %s: stopped", label)

    def _cycle(self, archiver: Archiver, client, label: str) -> None:
        count = archiver.run_once(client)
        status = self._runtime.status
        if count:
            logger.info("Account %s: processed %d message(s)", label, count)
            status.processed(self.key, count)
        status.set(self.key, "verbunden", "IDLE" if self.account.mode == "idle" else "Polling")

    def _run_poll(self, archiver: Archiver, client, label: str) -> None:
        while not self._stop.is_set():
            self._cycle(archiver, client, label)
            self._stop.wait(self._interval())

    def _run_idle(self, archiver: Archiver, client, label: str) -> None:
        self._cycle(archiver, client, label)
        while not self._stop.is_set():
            deadline = time.monotonic() + min(max(self._interval(), IDLE_SLICE), MAX_IDLE)
            client.idle()
            try:
                while not self._stop.is_set() and time.monotonic() < deadline:
                    if client.idle_check(timeout=IDLE_SLICE):
                        break
            finally:
                client.idle_done()
            if not self._stop.is_set():
                self._cycle(archiver, client, label)


def reconcile(runtime: Runtime, workers: dict, factory=None) -> dict:
    """Start, stop and restart workers so they match the configured accounts.

    Split out of the loop below so the decision - which worker survives a
    configuration change - can be tested without real IMAP connections.
    """
    factory = factory or (lambda account: _Worker(runtime, account))
    wanted = {account.id: account for account in runtime.accounts.enabled()}

    for account_id, worker in list(workers.items()):
        account = wanted.get(account_id)
        if account is None or account.fingerprint() != worker.fingerprint:
            # Settings changed or the account is gone. The worker notices
            # within a few seconds (see IDLE_SLICE).
            if account is not None:
                logger.info("Account %s: configuration changed, restarting", account.name)
            worker.stop()
            del workers[account_id]
            if account is None:
                runtime.status.forget(f"account:{account_id}")
        elif not worker.is_alive():
            del workers[account_id]

    for account_id, account in wanted.items():
        if account_id not in workers:
            worker = factory(account)
            workers[account_id] = worker
            worker.start()

    return workers


class Supervisor:
    """Keeps the workers in line with what is configured in the UI.

    Nothing is started before the service is *ready*: an archive exists and
    passed its write test, and the rules of an older installation have been
    taken over. Filing mail before that would put it into a directory that
    may not be the share, or file it without its rules.
    """

    def __init__(self, runtime: Runtime, factory=None):
        self.runtime = runtime
        self.workers: dict[int, object] = {}
        self._factory = factory
        self._pickup = (
            PickupRunner(
                lambda: runtime.options,
                runtime.mapping,
                runtime.storages,
                runtime.pickups,
                printing=runtime.printing,
            )
            if runtime.pickups is not None
            else None
        )
        self._next_pickup = 0.0
        self._was_ready: bool | None = None

    # --- readiness -------------------------------------------------------------

    def check_archive(self) -> bool:
        """Write-test the default archive when it changed, or retry a failure."""
        runtime = self.runtime
        status = runtime.status.archive
        archive = runtime.default_archive()
        if archive is None:
            status.ok, status.detail, status.fingerprint = False, "Kein Archiv eingerichtet.", ()
            return False

        fingerprint = (archive.id, *archive.fingerprint())
        due = status.checked_at is None or (
            not status.ok and time.time() - status.checked_at >= ARCHIVE_RETRY
        )
        if fingerprint == status.fingerprint and not due:
            return bool(status.ok)

        status.fingerprint = fingerprint
        status.checked_at = time.time()
        try:
            runtime.storages.get(archive.key).check_writable()
        except BaseException as exc:  # noqa: BLE001 - SystemExit is how check_writable reports
            if isinstance(exc, KeyboardInterrupt):
                raise
            status.ok, status.detail = False, str(exc) or exc.__class__.__name__
            logger.error("Archive %r is not usable: %s", archive.name, status.detail)
            return False

        status.ok = True
        status.detail = f"{archive.location()} ist erreichbar und beschreibbar."
        if archive.backend == "local" and not os.path.ismount(archive.path):
            # Not fatal - a directory on the container's own disk is a valid
            # (if unusual) choice - but it is exactly what a missing bind mount
            # looks like, and then every attachment would vanish with the next
            # rebuild. So it is said loudly.
            status.detail += (
                " Achtung: das Verzeichnis ist kein Mountpoint - ist das Share "
                "wirklich eingebunden?"
            )
            logger.warning("Archive %r: %s is not a mount point", archive.name, archive.path)
        logger.info("Archive %r -> %s", archive.name, archive.location())
        return True

    def ready(self) -> bool:
        runtime = self.runtime
        if not self.check_archive():
            return False
        if not rules_settled(runtime.settings):
            migrate_rule_file(runtime.settings, runtime.rule_store, runtime.storage)
            runtime.mapping.reload()
        return rules_settled(runtime.settings)

    # --- the loop ----------------------------------------------------------------

    def step(self) -> None:
        runtime = self.runtime
        ready = self.ready()
        if ready != self._was_ready:
            if ready:
                logger.info("Ready - watching the configured mailboxes and folders")
            else:
                logger.warning(
                    "Not ready yet (%s) - nothing is archived until the web UI shows an "
                    "archive that works",
                    runtime.status.archive.detail or "rules not taken over yet",
                )
            self._was_ready = ready

        if not ready:
            self.stop_all()
            return

        reconcile(runtime, self.workers, self._factory)

        # Folders are walked on their own schedule: the supervisor wakes up
        # every few seconds to notice UI changes, which is far more often than
        # a share should be listed over SMB.
        if self._pickup is not None and time.monotonic() >= self._next_pickup:
            try:
                filed = self._pickup.run_once()
                if filed:
                    logger.info("Picked up %d document(s) from the watched folders", filed)
                    runtime.status.processed("pickups", filed)
            except Exception:  # noqa: BLE001 - never let this stop the supervisor
                logger.exception("Pickup cycle failed")
            self._next_pickup = time.monotonic() + PICKUP_INTERVAL

    def pickup_problems(self) -> dict[int, str]:
        return self._pickup.problems() if self._pickup is not None else {}

    def run(self) -> None:
        runtime = self.runtime
        runtime.supervisor = self
        while True:
            self.step()
            runtime.changed.wait(SUPERVISOR_INTERVAL)
            if runtime.changed.is_set():
                runtime.changed.clear()
                # An archive may have been edited: test it again right away.
                runtime.status.archive.checked_at = None

    def stop_all(self) -> None:
        for worker in self.workers.values():
            worker.stop()
        self.workers.clear()


if __name__ == "__main__":
    main()
MAIL2NAS_EOF

# --- tests/test_mapping.py ---
cat > tests/test_mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import textwrap

import pytest

from mail2nas.mapping import (
    Mapping,
    MappingError,
    Rule,
    RuleStore,
    dump_rules,
    move_rule,
    rules_from_yaml,
    set_printing,
    validate_keyword,
)


def _store(tmp_path) -> RuleStore:
    return RuleStore(str(tmp_path / "state.db"))


def _write_rules(tmp_path, rules) -> None:
    """Store rules as (keyword, folder[, account]) tuples."""
    _store(tmp_path).save([Rule.create(*rule) for rule in rules])


def _write_mapping(path, content: str) -> None:
    """Store the rules of a YAML snippet - as an import or the migration would."""
    _store(path.parent).save(rules_from_yaml(textwrap.dedent(content)))


def _mapping(tmp_path, fallback_folder="unsorted") -> Mapping:
    return Mapping(_store(tmp_path), fallback_folder)


def load_rules(tmp_path) -> list[Rule]:
    return _store(tmp_path).load()


def save_rules(tmp_path, rules) -> None:
    _store(tmp_path).save(rules)


def test_resolve_matches_case_insensitive(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_the_fallback_follows_the_settings_page(tmp_path):
    current = {"folder": "unsorted"}
    mapping = Mapping(_store(tmp_path), lambda: current["folder"])

    current["folder"] = "sonstiges"

    assert mapping.resolve("Newsletter")[0] == "sonstiges"


def test_an_old_flat_file_keeps_its_longest_keyword_first_priority(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_no_rules_means_everything_goes_to_the_fallback(tmp_path):
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes_made_in_the_ui(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    _write_rules(tmp_path, [("RE", "invoices")])
    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "invoices"


def test_saving_through_the_mapping_takes_effect_at_once(tmp_path):
    mapping = _mapping(tmp_path)

    mapping.save([Rule.create("LS", "lieferscheine")])

    assert mapping.resolve("LS 7")[0] == "lieferscheine"
    assert [r.keyword for r in load_rules(tmp_path)] == ["LS"]


def test_the_order_survives_the_database(tmp_path):
    rules = [Rule.create(k, "x") for k in ("Zeta", "Alpha", "Mitte")]
    save_rules(tmp_path, rules)

    assert [r.keyword for r in load_rules(tmp_path)] == ["Zeta", "Alpha", "Mitte"]


@pytest.mark.parametrize("text", ["RE: [unclosed\n", "- just\n- a\n- list\n"])
def test_an_unreadable_import_is_refused_with_a_reason(text):
    with pytest.raises(MappingError):
        rules_from_yaml(text)


def test_export_and_import_round_trip(tmp_path):
    rules = [
        Rule.create("Rechnungskorrektur", "korrekturen"),
        Rule.create("RE*", "rechnungen", "2", True, "1", "3"),
    ]

    assert rules_from_yaml(dump_rules(rules)) == rules


# --- priority: explicit order, first match wins --------------------------------


def test_first_matching_rule_wins_regardless_of_keyword_length(tmp_path):
    """Order is explicit now - a short keyword placed first beats a longer one."""
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


def test_moving_a_rule_up_changes_which_one_wins(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    rules = load_rules(tmp_path)

    save_rules(tmp_path, move_rule(rules, 1, -1))

    assert _mapping(tmp_path).resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


def test_moving_beyond_the_ends_is_a_no_op(tmp_path):
    rules = [Rule.create("A", "a"), Rule.create("B", "b")]

    assert [r.keyword for r in move_rule(rules, 0, -1)] == ["A", "B"]
    assert [r.keyword for r in move_rule(rules, 1, 1)] == ["A", "B"]


# --- legacy format --------------------------------------------------------------


def test_old_flat_file_is_read_with_its_original_priority(tmp_path):
    """The pre-2.0 format matched the longest keyword first; migration must not
    change which folder a mail lands in."""
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"
    assert mapping.resolve("RE-1")[0] == "rechnungen"


def test_the_export_uses_the_versioned_format(tmp_path):
    text = dump_rules([Rule.create("RE", "rechnungen", "2")])

    assert "version: 2" in text
    assert "keyword: RE" in text
    assert "account: '2'" in text


# --- wildcards --------------------------------------------------------------------


@pytest.mark.parametrize(
    "keyword,subject,expected",
    [
        ("RE*", "Ihre RE-4711", True),
        ("RE*2026", "RE-4711 vom 03.2026", True),
        ("RE*2026", "RE-4711 vom 03.2025", False),
        ("Rechn?ng", "Ihre Rechnung", True),
        ("Rechn?ng", "Ihre Rechnuung", False),
        ("*Rechnung*", "Ihre Rechnung 1", True),
        ("Rechnung", "Ihre RECHNUNG 1", True),
    ],
)
def test_wildcard_and_case_matching(tmp_path, keyword, subject, expected):
    _write_rules(tmp_path, [(keyword, "treffer")])

    folder, _ = _mapping(tmp_path).resolve(subject)

    assert (folder == "treffer") is expected


def test_wildcards_stay_within_substring_search(tmp_path):
    """A pattern is not anchored, so it may match in the middle of a subject."""
    _write_rules(tmp_path, [("RE*47", "treffer")])

    assert _mapping(tmp_path).resolve("Betreff: Ihre RE-4711 anbei")[0] == "treffer"


def test_a_regex_metacharacter_in_a_keyword_is_literal(tmp_path):
    """Only * and ? are wildcards - the rest must not be interpreted."""
    _write_rules(tmp_path, [("RE.*", "treffer")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("RE.4711")[0] == "treffer"
    assert mapping.resolve("REX4711")[0] == "unsorted"


def test_keyword_of_only_wildcards_is_rejected():
    with pytest.raises(MappingError):
        validate_keyword("***", [])


# --- per-account rules --------------------------------------------------------------


def test_a_rule_can_be_limited_to_one_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen", "2")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="2")[0] == "rechnungen"
    assert mapping.resolve("Rechnung 1", account_id="1")[0] == "unsorted"


def test_rules_for_all_accounts_match_every_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="7")[0] == "rechnungen"


def test_an_account_specific_rule_is_skipped_for_other_accounts(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "nur-konto-2", "2"), ("Rechnung", "alle")])

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung", account_id="2")[0] == "nur-konto-2"
    assert mapping.resolve("Rechnung", account_id="1")[0] == "alle"


def test_a_pattern_with_too_many_wildcards_is_rejected_in_the_ui():
    with pytest.raises(MappingError, match="Platzhalter"):
        validate_keyword("a*b*c*d*e*f*g", [])


def test_a_hand_written_pattern_with_too_many_wildcards_degrades_to_literal(tmp_path):
    """Loaded from the share it must not raise - and must not be run as a regex."""
    _write_mapping(tmp_path / "mapping.yaml", 'version: 2\nrules:\n- keyword: "a*b*c*d*e*f*g"\n  folder: t\n')

    mapping = _mapping(tmp_path)

    assert mapping.resolve("a" * 200 + "g")[0] == "unsorted"
    assert mapping.resolve("a*b*c*d*e*f*g")[0] == "t"


def test_matching_a_huge_body_stays_bounded(tmp_path):
    """A wildcard pattern must not be run against an unbounded amount of text."""
    import time

    _write_rules(tmp_path, [("Rechnung*Ende", "treffer")])
    mapping = _mapping(tmp_path)

    started = time.monotonic()
    folder, _ = mapping.resolve("Rechnung " + ("x" * 2_000_000))
    assert folder == "unsorted"
    assert time.monotonic() - started < 5


# --- printing per rule ------------------------------------------------------------


def test_a_rule_carries_its_print_settings(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: Rechnung
            folder: rechnungen
            print: true
            printer: "3"
    """)

    rule = _mapping(tmp_path).match("Rechnung 4711")

    assert (rule.folder, rule.print_attachments, rule.printer) == ("rechnungen", True, "3")


def test_a_rule_without_print_settings_prints_nothing(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    rule = _mapping(tmp_path).match("RE-1")

    assert rule.print_attachments is False
    assert rule.printer == ""


def test_print_settings_survive_a_save_and_reload(tmp_path):
    save_rules(tmp_path, [Rule.create("RE", "rechnungen", "all", True, "2")])

    reloaded = load_rules(tmp_path)[0]

    assert (reloaded.print_attachments, reloaded.printer) == (True, "2")


def test_an_export_without_printing_stays_short(tmp_path):
    text = dump_rules([Rule.create("RE", "rechnungen")])

    assert "print" not in text
    assert "printer" not in text


def test_a_hand_written_yes_is_read_as_printing(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: RE
            folder: rechnungen
            print: "ja"
    """)

    assert _mapping(tmp_path).match("RE-1").print_attachments is True


def test_switching_printing_off_drops_the_printer(tmp_path):
    rule = Rule.create("RE", "rechnungen", "all", True, "2")

    assert set_printing(rule, False, "2").printer == ""
    assert set_printing(rule, True, "5").printer == "5"


def test_match_returns_nothing_when_no_rule_applies(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    assert _mapping(tmp_path).match("Newsletter") is None
MAIL2NAS_EOF

# --- tests/test_filenames.py ---
cat > tests/test_filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os

import pytest

from mail2nas.filenames import (
    safe_join,
    sanitize_filename,
    sanitize_path_segment,
    unique_path,
    write_atomic,
)


def test_sanitize_filename_replaces_unsafe_characters():
    assert sanitize_filename("Rechnung 12/03 (Kopie).pdf") == "Rechnung_12_03_Kopie_.pdf"


def test_sanitize_filename_handles_umlauts():
    result = sanitize_filename("Lieferschein Übersicht.pdf")

    assert result.endswith(".pdf")
    assert " " not in result


def test_sanitize_filename_never_empty():
    assert sanitize_filename("???") == "attachment"


def test_unique_path_avoids_overwriting_existing_file(tmp_path):
    existing = tmp_path / "invoice.pdf"
    existing.write_bytes(b"first")

    result = unique_path(tmp_path, "invoice.pdf")

    assert result != existing
    assert result.name == "invoice_1.pdf"


def test_unique_path_returns_original_when_free(tmp_path):
    result = unique_path(tmp_path, "invoice.pdf")

    assert result == tmp_path / "invoice.pdf"


# --- path segment sanitizing -------------------------------------------------


def test_sanitize_path_segment_keeps_readable_folder_names():
    assert sanitize_path_segment("Rechnungen 2026") == "Rechnungen 2026"


def test_sanitize_path_segment_strips_separators_and_reserved_chars():
    assert "/" not in sanitize_path_segment("a/b")
    assert "\\" not in sanitize_path_segment("a\\b")
    assert ":" not in sanitize_path_segment("C:name")


def test_sanitize_path_segment_strips_trailing_dot_and_space():
    assert sanitize_path_segment("rechnungen. ") == "rechnungen"


# --- safe_join: the mapping.yaml target folders are untrusted -----------------


def test_safe_join_allows_plain_and_nested_folders(tmp_path):
    assert safe_join(tmp_path, "rechnungen") == tmp_path / "rechnungen"
    assert safe_join(tmp_path, "rechnungen/2026") == tmp_path / "rechnungen" / "2026"


@pytest.mark.parametrize(
    "hostile",
    [
        "../outside",
        "../../../../tmp/pwned",
        "rechnungen/../../outside",
        "..",
    ],
)
def test_safe_join_refuses_parent_directory_escape(tmp_path, hostile):
    with pytest.raises(ValueError):
        safe_join(tmp_path, hostile)


@pytest.mark.parametrize("hostile", ["/etc/cron.d", "/tmp/pwned", "//srv/other"])
def test_safe_join_refuses_absolute_paths(tmp_path, hostile):
    # Path("/mnt/nas") / "/etc" would otherwise yield "/etc" outright.
    with pytest.raises(ValueError):
        safe_join(tmp_path, hostile)


def test_safe_join_refuses_backslash_escape(tmp_path):
    with pytest.raises(ValueError):
        safe_join(tmp_path, r"..\..\outside")


@pytest.mark.parametrize("empty", ["", "   ", "/", "./"])
def test_safe_join_refuses_empty_target(tmp_path, empty):
    with pytest.raises(ValueError):
        safe_join(tmp_path, empty)


# --- atomic writes -----------------------------------------------------------


def test_write_atomic_writes_content(tmp_path):
    target = tmp_path / "invoice.pdf"

    write_atomic(target, b"%PDF-1.4 payload")

    assert target.read_bytes() == b"%PDF-1.4 payload"


def test_write_atomic_leaves_no_temp_files_behind(tmp_path):
    write_atomic(tmp_path / "invoice.pdf", b"data")

    assert [p.name for p in tmp_path.iterdir()] == ["invoice.pdf"]


def test_write_atomic_does_not_leave_partial_file_on_failure(tmp_path, monkeypatch):
    target = tmp_path / "invoice.pdf"

    class Boom(Exception):
        pass

    real_replace = os.replace

    def failing_replace(src, dst):
        raise Boom("simulated crash before rename")

    monkeypatch.setattr(os, "replace", failing_replace)
    with pytest.raises(Boom):
        write_atomic(target, b"partial")
    monkeypatch.setattr(os, "replace", real_replace)

    assert not target.exists()
    assert list(tmp_path.iterdir()) == []
MAIL2NAS_EOF

# --- tests/test_archiver.py ---
cat > tests/test_archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import email
import textwrap
from dataclasses import replace
from email.message import EmailMessage

from mail2nas.accounts import Account
from mail2nas.addresses import AddressStore
from mail2nas.archives import ArchiveStore, StorageSet
from mail2nas.archiver import MAX_RECIPIENTS, Archiver, recipients_of
from mail2nas.config import DEFAULT_PRINTABLE_EXTENSIONS, Config
from mail2nas.legacy import LegacyEnv
from mail2nas.mapping import Mapping, RuleStore, rules_from_yaml
from mail2nas.options import Options
from mail2nas.printers import PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    parse_extensions,
)
from mail2nas.state import ProcessedStore
from mail2nas.storage import LocalStorage

TEST_ACCOUNT = Account(
    id=1, name="Test", host="imap.example.com", port=993, ssl=True,
    user="u", password="p", folder="INBOX", mode="poll",
    processed_folder="", oversized_folder="", enabled=True,
)


def _account(**overrides) -> Account:
    return replace(TEST_ACCOUNT, **overrides)


def _make_options(**overrides) -> Options:
    """The settings as they would be stored, with test-friendly overrides."""
    return replace(Options(), **overrides)


def _make_config(tmp_path, **overrides) -> Config:
    """The (infrastructure-only) container configuration for a test."""
    defaults = dict(state_db_path=str(tmp_path / "state.db"), web_host="127.0.0.1")
    defaults.update(overrides)
    return Config(**defaults)


def _make_legacy(**overrides) -> LegacyEnv:
    """An old-style .env, as `legacy.py` reads it."""
    return replace(LegacyEnv(), **overrides)


def _seed_config(tmp_path, **overrides):
    """An old .env plus where the database lives - what the seeding tests need.

    The seed functions read the old variable names as attributes, exactly as
    they come out of `LegacyEnv`.
    """
    from dataclasses import fields
    from types import SimpleNamespace

    defaults = dict(
        imap_host="imap.example.com", imap_user="u", imap_password="p", storage_root=str(tmp_path)
    )
    defaults.update(overrides)
    legacy = _make_legacy(**defaults)
    values = {spec.name: getattr(legacy, spec.name) for spec in fields(legacy)}
    return SimpleNamespace(**values, state_db_path=str(tmp_path / "state.db"))


def _make_runtime(tmp_path, with_archive: bool = True, environ=None, **config_overrides):
    """A wired-up service as `main` builds it - with a local archive in tmp_path.

    `environ` is the (old) .env to take over; empty by default, i.e. a fresh
    installation.
    """
    from mail2nas.main import build_runtime

    runtime = build_runtime(_make_config(tmp_path, **config_overrides), environ or {})
    if with_archive:
        runtime.archives.add(name="Test", backend="local", path=str(tmp_path))
    return runtime


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_mapping(tmp_path, mapping_content: str | None = None, fallback="unsorted") -> Mapping:
    """Rules as the database holds them, written from a YAML snippet."""
    store = RuleStore(str(tmp_path / "state.db"))
    if mapping_content is not None:
        store.save(rules_from_yaml(textwrap.dedent(mapping_content)))
    return Mapping(store, fallback)


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    account: Account | None = None,
    printing=None,
    addresses=None,
    storages=None,
    blocked_extensions=None,
    **option_overrides,
) -> Archiver:
    options = _make_options(**option_overrides)
    mapping = _make_mapping(tmp_path, mapping_content, options.fallback_folder)
    if blocked_extensions is not None:
        # A callable, so a test can change the list between two messages -
        # the way the settings page does while the service runs.
        base = options
        options = lambda: replace(base, blocked_extensions=blocked_extensions())  # noqa: E731
    return Archiver(
        options,
        mapping,
        ProcessedStore(str(tmp_path / "state.db")),
        storages if storages is not None else LocalStorage(str(tmp_path)),
        account or TEST_ACCOUNT,
        printing,
        addresses,
    )


class FakeIMAPClient:
    """Minimal stand-in for imapclient.IMAPClient, just enough for _process_message."""

    def __init__(self, uid: int, raw: bytes):
        self._uid = uid
        self._raw = raw
        self.flags_added: list[tuple[list[int], list[bytes]]] = []
        self.moved_to: list[tuple[list[int], str]] = []

    def fetch(self, uids, parts):
        assert uids == [self._uid]
        result: dict = {}
        for uid in uids:
            entry = {}
            if "RFC822.SIZE" in parts:
                entry[b"RFC822.SIZE"] = len(self._raw)
            if "RFC822" in parts:
                entry[b"RFC822"] = self._raw
            result[uid] = entry
        return result

    def add_flags(self, uids, flags):
        self.flags_added.append((list(uids), list(flags)))

    def move(self, uids, folder):
        self.moved_to.append((list(uids), folder))


def _build_message(subject: str, attachments: list[tuple[str, bytes]]) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    for filename, payload in attachments:
        msg.add_attachment(payload, maintype="application", subtype="octet-stream", filename=filename)
    return bytes(msg)


# --- attachment discovery / filename building -------------------------------


def test_iter_attachments_finds_named_parts(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Rechnung 123"
    msg.set_content("Hallo")
    msg.add_attachment(b"%PDF-1.4 fake", maintype="application", subtype="pdf", filename="rechnung.pdf")

    archiver = _make_archiver(tmp_path)
    attachments = list(archiver._iter_attachments(msg))

    assert len(attachments) == 1
    filename, payload = attachments[0]
    assert filename == "rechnung.pdf"
    assert payload.startswith(b"%PDF")


def test_iter_attachments_ignores_plain_body(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Newsletter"
    msg.set_content("Nur Text, kein Anhang")

    archiver = _make_archiver(tmp_path)

    assert list(archiver._iter_attachments(msg)) == []


def test_build_filename_date_sender_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date_sender")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_lieferant_example.com_rechnung.pdf"


def test_build_filename_none_prefix_keeps_original_name(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="none")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "rechnung.pdf"


def test_build_filename_date_only_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_rechnung.pdf"


# --- per-attachment folder resolution ----------------------------------------


def test_plan_prefers_attachment_filename_over_mail_subject(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            RE: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    # Mail-level match would be "rechnungen" (subject contains RE), but this
    # specific attachment's own filename literally says "Lieferschein".
    mail_rule = archiver.mapping.match("RE-2024-001 mit Lieferschein")

    plan = archiver._plan_attachment("Lieferschein_4711.pdf", mail_rule)

    assert plan.folder == "lieferscheine"
    assert plan.keyword == "Lieferschein"
    assert plan.quarantined is False


def test_plan_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_rule = archiver.mapping.match("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    plan = archiver._plan_attachment("anhang1.pdf", mail_rule)

    assert plan.folder == "rechnungen"
    assert plan.keyword == "RE"
    assert plan.quarantined is False


def test_plan_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    plan = archiver._plan_attachment("Rechnung.exe", None)

    assert plan.folder == "quarantaene"
    assert plan.quarantined is True


# --- full message processing (size/count limits, quarantine, mail-level) ----


def test_process_message_splits_multiple_attachments_by_filename(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            Rechnung: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice-bytes"), ("Lieferschein_42.pdf", b"delivery-bytes")],
    )
    client = FakeIMAPClient(uid=1, raw=raw)

    archiver._process_message(client, 1)

    assert any(p.name.endswith("Rechnung_42.pdf") for p in (tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("Lieferschein_42.pdf") for p in (tmp_path / "lieferscheine").glob("*"))


def test_process_message_skips_oversized_message_without_reading_body(tmp_path):
    archiver = _make_archiver(tmp_path, max_message_size_mb=1)
    huge_raw = _build_message("Rechnung riesig", [("rechnung.pdf", b"x" * (2 * 1024 * 1024))])
    client = FakeIMAPClient(uid=7, raw=huge_raw)

    result = archiver._process_message(client, 7)

    assert result is True
    assert client.flags_added == [([7], [b"\\Seen"])]
    assert not (tmp_path / "rechnungen").exists()


def test_process_message_skips_only_oversized_attachment(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachment_size_mb=1, max_message_size_mb=50
    )
    raw = _build_message(
        "RE-1",
        [("gross.pdf", b"x" * (2 * 1024 * 1024)), ("klein.pdf", b"klein")],
    )
    client = FakeIMAPClient(uid=3, raw=raw)

    archiver._process_message(client, 3)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("klein.pdf") for p in saved)
    assert not any(p.name.endswith("gross.pdf") for p in saved)


def test_process_message_caps_attachment_count(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachments_per_message=2
    )
    raw = _build_message(
        "RE-1",
        [(f"a{i}.pdf", b"data") for i in range(5)],
    )
    client = FakeIMAPClient(uid=4, raw=raw)

    archiver._process_message(client, 4)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert len(saved) == 2


def test_process_message_quarantines_blocked_attachment(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ...")])
    client = FakeIMAPClient(uid=5, raw=raw)

    archiver._process_message(client, 5)

    assert not (tmp_path / "rechnungen").exists() or not any((tmp_path / "rechnungen").glob("*"))
    quarantined = list((tmp_path / "quarantaene").glob("*"))
    assert len(quarantined) == 1


def test_process_message_is_idempotent_for_already_processed_message_id(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("rechnung.pdf", b"data")])
    client = FakeIMAPClient(uid=6, raw=raw)

    archiver._process_message(client, 6)
    first_run_files = list((tmp_path / "rechnungen").glob("*"))
    archiver._process_message(client, 6)
    second_run_files = list((tmp_path / "rechnungen").glob("*"))

    assert len(first_run_files) == 1
    assert len(second_run_files) == 1


# --- untrusted mapping targets must not escape the storage root -------------


def test_process_message_confines_relative_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside-escape\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path.parent / "outside-escape").exists()
    # rejected target falls back rather than being written outside
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_process_message_confines_absolute_traversal_target(tmp_path):
    escape = tmp_path.parent / "absolute-escape"
    archiver = _make_archiver(tmp_path, mapping_content=f"RE: {escape}\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert not escape.exists()
    # rejected as a misconfiguration, so it lands in the fallback folder
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_target_parts_reject_escape_and_use_fallback(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver._target_parts("../evil") == ("unsorted",)
    assert archiver._target_parts("rechnungen") == ("rechnungen",)
    assert archiver._target_parts("rechnungen/2026") == ("rechnungen", "2026")


def test_nested_mapping_target_is_supported(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen/2026\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert any((tmp_path / "rechnungen" / "2026").glob("*"))


def test_quarantine_still_wins_over_a_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert not (tmp_path.parent / "outside").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_attachments_are_written_atomically_without_temp_leftovers(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    names = [p.name for p in (tmp_path / "rechnungen").iterdir()]
    assert len(names) == 1
    assert not any(n.startswith(".mail2nas-tmp-") for n in names)


# --- printing ----------------------------------------------------------------


class RecordingSpooler(Spooler):
    """A spooler that remembers jobs instead of handing them to CUPS."""

    def __init__(self, **kwargs):
        super().__init__(printable_extensions=parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS))
        self.jobs: list[tuple[str, str]] = []

    def print_bytes(self, printer, data, filename, title=""):
        self.jobs.append((printer.destination, filename))
        return "queued"

    @property
    def printed_on(self) -> list[str]:
        return [destination for destination, _ in self.jobs]


def _make_printing(tmp_path, *queues: str):
    """A print service with one printer per given queue name."""
    store = PrinterStore(str(tmp_path / "printers.db"))
    ids = [str(store.add(name=queue, destination=queue)) for queue in queues]
    spooler = RecordingSpooler()
    return PrintService(store, spooler), spooler, ids


def test_a_mailbox_can_print_every_attachment(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
    )
    raw = _build_message("Newsletter", [("prospekt.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert spooler.printed_on == ["drucker_a"]
    # still archived: printing is an addition, not a replacement
    assert any((tmp_path / "unsorted").glob("*"))


def test_a_rule_can_print_only_what_it_matches(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_b")
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{printer_id}"
              - keyword: Lieferschein
                folder: lieferscheine
        """,
        printing=printing,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice"), ("Lieferschein_42.pdf", b"delivery")],
    )

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert [name for _, name in spooler.jobs] == [
        "unknown-date_lieferant_example.com_Rechnung_42.pdf"
    ]
    assert spooler.printed_on == ["drucker_b"]


def test_the_rule_printer_wins_over_the_mailbox_printer(tmp_path):
    printing, spooler, (rule_printer, account_printer) = _make_printing(
        tmp_path, "drucker_regel", "drucker_konto"
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{rule_printer}"
        """,
        account=_account(print_attachments=True, printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert spooler.printed_on == ["drucker_regel"]


def test_a_rule_without_its_own_printer_uses_the_mailbox_one(tmp_path):
    printing, spooler, (account_printer,) = _make_printing(tmp_path, "drucker_konto")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
        """,
        account=_account(printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert spooler.printed_on == ["drucker_konto"]


def test_print_only_mailboxes_do_not_write_to_the_share(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    assert spooler.printed_on == ["drucker_a"]
    assert not (tmp_path / "rechnungen").exists()


def test_a_blocked_attachment_is_quarantined_and_never_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        # print everything, archive nothing - the executable must still be
        # kept, and must still not reach the printer.
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=6, raw=raw), 6)

    assert spooler.jobs == []
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_nothing_is_printed_without_a_printer(tmp_path, caplog):
    printing, spooler, _ = _make_printing(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    with caplog.at_level("WARNING"):
        archiver._process_message(FakeIMAPClient(uid=7, raw=raw), 7)

    assert spooler.jobs == []
    assert "no usable printer" in caplog.text
    # the attachment is still filed - printing is the part that failed
    assert any((tmp_path / "rechnungen").glob("*"))


def test_printing_can_be_switched_off_globally(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
        printing_enabled=False,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=8, raw=raw), 8)

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*"))


def test_a_failing_printer_does_not_stop_the_archiving(tmp_path):
    class BrokenSpooler(RecordingSpooler):
        def print_bytes(self, printer, data, filename, title=""):
            raise PrintError("Drucker offline")

    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name="Kaputt", destination="drucker_a"))
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=PrintService(store, BrokenSpooler()),
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=9, raw=raw), 9)

    assert any((tmp_path / "rechnungen").glob("*"))


# --- printing by the address a mail was sent to ------------------------------


def _addressed_message(
    to: str = "drucker@firma.de",
    sender: str = "kollege@firma.de",
    subject: str = "Bitte drucken",
    filename: str = "vertrag.pdf",
    extra_headers: dict | None = None,
) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to
    for header, value in (extra_headers or {}).items():
        msg[header] = value
    msg.set_content("Anbei.")
    msg.add_attachment(b"DATA", maintype="application", subtype="pdf", filename=filename)
    return bytes(msg)


def _addresses(tmp_path, **fields) -> AddressStore:
    """An address store holding one rule, with print-to-a-queue defaults."""
    store = AddressStore(str(tmp_path / "addresses.db"))
    values = dict(name="Drucker Buero", recipient="drucker@firma.de", print_attachments=True)
    values.update(fields)
    store.add(**values)
    return store


def test_recipients_are_read_from_the_delivery_headers():
    """An alias only survives in Delivered-To once To: has been rewritten."""
    raw = _addressed_message(
        to="liste@firma.de", extra_headers={"Delivered-To": "drucker@firma.de", "Cc": "chef@firma.de"}
    )

    found = recipients_of(email.message_from_bytes(raw))

    assert "drucker@firma.de" in found
    assert "liste@firma.de" in found
    assert "chef@firma.de" in found


def test_recipient_extraction_is_bounded(tmp_path):
    """A mail with thousands of recipients must not make matching expensive."""
    msg = EmailMessage()
    msg["Subject"] = "Massenmail"
    msg["From"] = "a@b.c"
    msg["To"] = ", ".join(f"user{i}@firma.de" for i in range(200))
    msg.set_content("x")

    assert len(recipients_of(msg)) == MAX_RECIPIENTS


def test_mail_to_the_configured_address_is_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_addressed_message()), 1)

    assert spooler.printed_on == ["buero_eg"]


def test_mail_to_another_address_is_not_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )

    archiver._process_message(
        FakeIMAPClient(uid=2, raw=_addressed_message(to="archiv@firma.de")), 2
    )

    assert spooler.printed_on == []


def test_an_alias_in_delivered_to_is_enough(tmp_path):
    """The usual setup: the alias is delivered into a shared mailbox."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )
    raw = _addressed_message(
        to="archiv@firma.de", extra_headers={"Delivered-To": "drucker@firma.de"}
    )

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert spooler.printed_on == ["buero_eg"]


def test_a_sender_restriction_keeps_strangers_from_printing(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, sender="@firma.de"),
    )

    archiver._process_message(
        FakeIMAPClient(uid=4, raw=_addressed_message(sender="fremder@example.com")), 4
    )

    assert spooler.printed_on == []


def test_the_address_decides_the_folder(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=_addresses(tmp_path, print_attachments=False, folder="ausdrucke"),
    )

    archiver._process_message(
        FakeIMAPClient(uid=5, raw=_addressed_message(filename="Vertrag_7.pdf")), 5
    )

    assert any((tmp_path / "ausdrucke").glob("*"))
    assert not (tmp_path / "vertraege").exists()


def test_without_a_folder_the_keyword_rules_still_decide(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=_addresses(tmp_path, print_attachments=False),
    )

    archiver._process_message(
        FakeIMAPClient(uid=6, raw=_addressed_message(filename="Vertrag_7.pdf")), 6
    )

    assert any((tmp_path / "vertraege").glob("*"))


def test_an_address_can_print_without_filing(tmp_path):
    """A print-only alias: paper comes out, the share stays clean."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, archive_attachments=False),
    )

    archiver._process_message(FakeIMAPClient(uid=7, raw=_addressed_message()), 7)

    assert spooler.printed_on == ["buero_eg"]
    assert not any(tmp_path.glob("unsorted/*"))


def test_an_address_can_file_without_printing(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
        addresses=_addresses(tmp_path, print_attachments=False, folder="nur_ablage"),
    )

    archiver._process_message(FakeIMAPClient(uid=8, raw=_addressed_message()), 8)

    # The address is the more specific statement, so it wins over the mailbox.
    assert spooler.printed_on == []
    assert any((tmp_path / "nur_ablage").glob("*"))


def test_the_address_printer_beats_the_rule_and_the_mailbox(tmp_path):
    printing, spooler, (address_printer, rule_printer, mailbox_printer) = _make_printing(
        tmp_path, "per_adresse", "per_regel", "per_postfach"
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Vertrag
                folder: vertraege
                print: true
                printer: "{rule_printer}"
        """,
        account=_account(print_attachments=True, printer=mailbox_printer),
        printing=printing,
        addresses=_addresses(tmp_path, printer=address_printer),
    )

    archiver._process_message(
        FakeIMAPClient(uid=9, raw=_addressed_message(filename="Vertrag_7.pdf")), 9
    )

    assert spooler.printed_on == ["per_adresse"]


def test_an_address_without_its_own_printer_falls_back_to_the_mailbox(tmp_path):
    printing, spooler, (mailbox_printer,) = _make_printing(tmp_path, "per_postfach")
    archiver = _make_archiver(
        tmp_path,
        account=_account(printer=mailbox_printer),
        printing=printing,
        addresses=_addresses(tmp_path, printer=""),
    )

    archiver._process_message(FakeIMAPClient(uid=10, raw=_addressed_message()), 10)

    assert spooler.printed_on == ["per_postfach"]


def test_a_blocked_attachment_is_never_printed_even_for_an_address(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, archive_attachments=False),
    )

    archiver._process_message(
        FakeIMAPClient(uid=11, raw=_addressed_message(filename="rechnung.exe")), 11
    )

    assert spooler.printed_on == []
    # ... and it is filed despite "print only", so it can be looked at
    assert any((tmp_path / "quarantaene").glob("*"))


def test_a_printer_that_is_gone_does_not_stop_the_filing(tmp_path):
    printing, spooler, _ = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer="999"),
    )

    archiver._process_message(FakeIMAPClient(uid=12, raw=_addressed_message()), 12)

    assert spooler.printed_on == []
    assert any((tmp_path / "unsorted").glob("*"))


def test_without_address_rules_nothing_changes(tmp_path):
    """The feature is opt-in: an install with no rules behaves as before."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(tmp_path, printing=printing, addresses=None)

    archiver._process_message(FakeIMAPClient(uid=13, raw=_addressed_message()), 13)

    assert spooler.printed_on == []
    assert any((tmp_path / "unsorted").glob("*"))


def test_end_to_end_a_mail_to_the_address_reaches_the_lp_command(tmp_path):
    """The whole chain with no stub in the middle: message in, `lp` called.

    Everything else here fakes the spooler, which is what makes this worth
    having: it is the only test that proves the address rule, the printer
    record and the real `lp` argument building fit together.
    """
    fake_lp = tmp_path / "lp"
    log = tmp_path / "lp.log"
    fake_lp.write_text(
        "#!/bin/sh\n"
        f'echo "$@" >> {log}\n'
        "exit 0\n",
        encoding="utf-8",
    )
    fake_lp.chmod(0o755)

    printers = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = printers.add(
        name="Buero", destination="Buero_MFP", server="cups.lan:631", options="media=A4"
    )
    printing = PrintService(printers, Spooler(lp_binary=str(fake_lp), timeout=30))

    archiver = Archiver(
        _make_options(),
        _make_mapping(tmp_path),
        ProcessedStore(str(tmp_path / "state.db")),
        LocalStorage(str(tmp_path)),
        TEST_ACCOUNT,
        printing,
        _addresses(tmp_path, printer=str(printer_id)),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_addressed_message()), 1)

    called = log.read_text(encoding="utf-8")
    assert "-h cups.lan:631" in called
    assert "-d Buero_MFP" in called
    assert "-o media=A4" in called
    # and the document is on the share as well
    assert any((tmp_path / "unsorted").glob("*"))


# --- several archives ----------------------------------------------------------


def _two_archives(tmp_path):
    """<tmp_path> as the default archive, <tmp_path>/nas2 as the second."""
    second = tmp_path / "nas2"
    second.mkdir(exist_ok=True)
    archives = ArchiveStore(str(tmp_path / "archives.db"))
    archives.add(name="Haupt", backend="local", path=str(tmp_path))
    second_key = str(archives.add(name="NAS 2", backend="local", path=str(second)))
    return StorageSet(archives, LocalStorage(str(tmp_path))), second, second_key


def test_a_rule_files_onto_the_archive_it_names(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "{second_key}"
        """,
        storages=storages,
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_build_message("RE-1", [("b.pdf", b"D")])), 1)

    assert len(list((second / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "rechnungen").exists()


def test_a_rule_without_an_archive_uses_the_default_one(tmp_path):
    storages, second, _ = _two_archives(tmp_path)
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n", storages=storages)

    archiver._process_message(FakeIMAPClient(uid=2, raw=_build_message("RE-1", [("b.pdf", b"D")])), 2)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (second / "rechnungen").exists()


def test_a_deleted_archive_falls_back_instead_of_losing_the_attachment(tmp_path):
    storages, _, _ = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "999"
        """,
        storages=storages,
    )

    archiver._process_message(FakeIMAPClient(uid=3, raw=_build_message("RE-1", [("b.pdf", b"D")])), 3)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_an_address_rule_can_send_a_document_to_another_archive(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    addresses = _addresses(tmp_path, print_attachments=False, folder="ausdrucke",
                           archive=second_key)
    archiver = _make_archiver(tmp_path, addresses=addresses, storages=storages)

    archiver._process_message(FakeIMAPClient(uid=4, raw=_addressed_message()), 4)

    assert len(list((second / "ausdrucke").glob("*"))) == 1


def test_the_address_archive_wins_over_the_rule_folder_archive(tmp_path):
    """"File it where it usually goes, but on that NAS" has to work."""
    storages, second, second_key = _two_archives(tmp_path)
    addresses = _addresses(tmp_path, print_attachments=False, archive=second_key)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=addresses,
        storages=storages,
    )

    archiver._process_message(
        FakeIMAPClient(uid=5, raw=_addressed_message(filename="Vertrag_7.pdf")), 5
    )

    assert len(list((second / "vertraege").glob("*"))) == 1


def test_a_quarantined_attachment_stays_on_the_archive_it_was_meant_for(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "{second_key}"
        """,
        storages=storages,
    )

    archiver._process_message(
        FakeIMAPClient(uid=6, raw=_build_message("RE-1", [("Rechnung.exe", b"MZ")])), 6
    )

    assert len(list((second / "quarantaene").glob("*"))) == 1


# --- the quarantine list is read live -------------------------------------------


def test_the_blocked_extension_list_is_read_per_message(tmp_path):
    """Editing it in the web UI must not need a restart."""
    blocked = {"value": frozenset()}
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", blocked_extensions=lambda: blocked["value"]
    )

    archiver._process_message(
        FakeIMAPClient(uid=7, raw=_build_message("RE-1", [("a.exe", b"MZ")])), 7
    )
    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1

    blocked["value"] = frozenset({"exe"})
    archiver._process_message(
        FakeIMAPClient(uid=8, raw=_build_message("RE-2", [("b.exe", b"MZ")])), 8
    )

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


# --- "print only" never loses an attachment ----------------------------------


def test_print_only_files_the_attachment_when_the_printer_fails(tmp_path):
    class BrokenSpooler(RecordingSpooler):
        def print_bytes(self, printer, data, filename, title=""):
            raise PrintError("Drucker offline")

    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name="Kaputt", destination="drucker_a"))
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=PrintService(store, BrokenSpooler()),
    )

    archiver._process_message(
        FakeIMAPClient(uid=11, raw=_build_message("RE-1", [("beleg.pdf", b"DATA")])), 11
    )

    assert any((tmp_path / "rechnungen").glob("*"))


def test_print_only_without_any_printer_files_the_attachment(tmp_path):
    printing, spooler, _ = _make_printing(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, archive_attachments=False),
        printing=printing,
    )

    archiver._process_message(
        FakeIMAPClient(uid=12, raw=_build_message("RE-1", [("beleg.pdf", b"DATA")])), 12
    )

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*"))


def test_print_only_with_an_unprintable_format_files_it(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )

    archiver._process_message(
        FakeIMAPClient(uid=13, raw=_build_message("RE-1", [("tabelle.xlsx", b"PK")])), 13
    )

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*tabelle.xlsx"))


def test_settings_changed_in_the_ui_apply_to_the_next_message(tmp_path):
    current = {"options": _make_options()}
    archiver = Archiver(
        lambda: current["options"],
        _make_mapping(tmp_path),
        ProcessedStore(str(tmp_path / "state.db")),
        LocalStorage(str(tmp_path)),
        TEST_ACCOUNT,
    )

    current["options"] = _make_options(fallback_folder="sonstiges")
    archiver._process_message(
        FakeIMAPClient(uid=14, raw=_build_message("Hallo", [("a.pdf", b"x")])), 14
    )

    assert any((tmp_path / "sonstiges").glob("*"))
MAIL2NAS_EOF

# --- tests/test_config.py ---
cat > tests/test_config.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.config import Config, parse_extension_list
from mail2nas.legacy import LEGACY_VARIABLES, LegacyEnv

INFRA = ("STATE_DB_PATH", "WEB_HOST", "WEB_PORT", "WEB_PASSWORD", "WEB_COOKIE_SECURE",
         "LP_BINARY", "LPSTAT_BINARY")


@pytest.fixture
def clean_env(monkeypatch):
    for key in (*INFRA, *LEGACY_VARIABLES, "NAS_PATH"):
        monkeypatch.delenv(key, raising=False)
    return monkeypatch


# --- the container configuration ----------------------------------------------


def test_an_empty_env_is_enough_to_start(clean_env):
    """No mailbox, no share, no password: all of that is set up in the web UI."""
    config = Config.from_env()

    assert config.state_db_path == "/data/state.db"
    assert config.web_port == 8080
    assert config.web_password == ""


def test_old_variables_do_not_break_the_container_config(clean_env):
    clean_env.setenv("IMAP_MODE", "tippfehler")
    clean_env.setenv("MAX_ATTACHMENT_SIZE_MB", "viel")

    Config.from_env()  # must not raise - those values are the legacy reader's job


@pytest.mark.parametrize("value", ["0", "70000", "achtzig"])
def test_an_unusable_web_port_is_reported(clean_env, value):
    clean_env.setenv("WEB_PORT", value)

    with pytest.raises(SystemExit, match="WEB_PORT"):
        Config.from_env()


def test_lpstat_is_found_next_to_lp(clean_env):
    clean_env.setenv("LP_BINARY", "/opt/cups/bin/lp")

    assert Config.from_env().lpstat_binary == "/opt/cups/bin/lpstat"


def test_the_data_directory_is_next_to_the_database(clean_env):
    clean_env.setenv("STATE_DB_PATH", "/srv/mail2nas/state.db")

    assert Config.from_env().data_dir == "/srv/mail2nas"


def test_extension_lists_accept_every_separator_people_type():
    assert parse_extension_list(".EXE, com; bat  js") == {"exe", "com", "bat", "js"}


# --- reading an older .env ------------------------------------------------------


def test_a_fresh_env_describes_nothing_to_take_over(clean_env):
    legacy = LegacyEnv.from_environ()

    assert not legacy.has_mailbox
    assert not legacy.has_archive
    assert not legacy.has_options


def test_generation_1_docker_cifs_volume_becomes_direct_smb():
    """SMB credentials in the .env, no backend: Docker used to mount the share.

    Treating it as a mount would write into an empty directory inside the
    container - the one mistake an update must not make.
    """
    legacy = LegacyEnv.from_environ({
        "IMAP_HOST": "imap.x", "IMAP_USER": "u", "IMAP_PASSWORD": "p",
        "SMB_HOST": "nas", "SMB_SHARE": "Belege", "SMB_USER": "a", "SMB_PASSWORD": "b",
    })

    assert legacy.storage_backend == "smb"
    assert (legacy.smb_host, legacy.smb_share) == ("nas", "Belege")


def test_generation_2_host_mount_stays_a_mounted_directory():
    legacy = LegacyEnv.from_environ({
        "IMAP_HOST": "imap.x", "IMAP_USER": "u", "IMAP_PASSWORD": "p", "NAS_PATH": "/mnt/nas",
    })

    assert legacy.storage_backend == "local"
    assert legacy.storage_root == "/mnt/nas"


@pytest.mark.parametrize("backend", ["smb", "local"])
def test_an_explicit_backend_wins(backend):
    legacy = LegacyEnv.from_environ({
        "STORAGE_BACKEND": backend, "SMB_HOST": "nas", "SMB_SHARE": "Belege",
        "SMB_USER": "a", "SMB_PASSWORD": "b",
    })

    assert legacy.storage_backend == backend


def test_smb_without_a_share_is_not_taken_over():
    assert LegacyEnv.from_environ({"STORAGE_BACKEND": "smb", "SMB_HOST": "nas"}).storage_backend == ""


@pytest.mark.parametrize(
    "name,value,attribute,expected",
    [
        ("IMAP_PORT", "abc", "imap_port", 993),
        ("IMAP_MODE", "sofort", "imap_mode", "poll"),
        ("FILENAME_PREFIX", "egal", "filename_prefix", "date_sender"),
        ("MAX_ATTACHMENT_SIZE_MB", "0", "max_attachment_size_mb", 25),
        ("PRINTER_COPIES", "99", "printer_copies", 1),
    ],
)
def test_a_broken_old_value_falls_back_instead_of_stopping(name, value, attribute, expected):
    assert getattr(LegacyEnv.from_environ({name: value}), attribute) == expected


def test_old_values_are_read_with_their_old_meaning():
    legacy = LegacyEnv.from_environ({
        "IMAP_MODE": "IDLE", "MATCH_BODY": "true", "FALLBACK_FOLDER": "sonstiges",
        "BLOCKED_EXTENSIONS": "exe,js", "POLL_INTERVAL_SECONDS": "60",
    })

    assert legacy.imap_mode == "idle"
    assert legacy.match_body is True
    assert legacy.fallback_folder == "sonstiges"
    assert legacy.blocked_extensions == {"exe", "js"}
    assert legacy.poll_interval == 60
    assert legacy.has_options
MAIL2NAS_EOF

# --- tests/test_storage.py ---
cat > tests/test_storage.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import errno
import os
from pathlib import Path

import pytest

from mail2nas.storage import LocalStorage, SmbStorage


# --- local backend ------------------------------------------------------------


def test_accepts_a_writable_storage_root(tmp_path):
    LocalStorage(str(tmp_path)).check_writable()


def test_missing_storage_root_fails_fast(tmp_path):
    """An unmounted share must not be mistaken for an empty one."""
    with pytest.raises(SystemExit, match="does not exist"):
        LocalStorage(str(tmp_path / "not-mounted")).check_writable()


def test_storage_root_that_is_a_file_fails_fast(tmp_path):
    a_file = tmp_path / "afile"
    a_file.write_text("x", encoding="utf-8")

    with pytest.raises(SystemExit, match="does not exist or is not a directory"):
        LocalStorage(str(a_file)).check_writable()


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_storage_root_fails_fast(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        with pytest.raises(SystemExit, match="not writable"):
            LocalStorage(str(readonly)).check_writable()
    finally:
        readonly.chmod(0o700)


def test_local_save_unique_creates_directories_and_avoids_overwriting(tmp_path):
    storage = LocalStorage(str(tmp_path))

    first = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"one")
    second = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"two")

    assert first != second
    assert (tmp_path / "rechnungen" / "2026" / "beleg.pdf").read_bytes() == b"one"
    assert (tmp_path / "rechnungen" / "2026" / "beleg_1.pdf").read_bytes() == b"two"


def test_local_read_text_and_modified_time(tmp_path):
    storage = LocalStorage(str(tmp_path))
    (tmp_path / "mapping.yaml").write_text("RE: rechnungen\n", encoding="utf-8")

    assert storage.read_text("mapping.yaml") == "RE: rechnungen\n"
    assert storage.modified_time("mapping.yaml") > 0

    with pytest.raises(FileNotFoundError):
        storage.modified_time("nope.yaml")


# --- SMB backend: path building (no server involved) --------------------------


def _smb(**overrides) -> SmbStorage:
    defaults = dict(host="nas.local", share="Belege", user="mail2nas", password="secret")
    defaults.update(overrides)
    return SmbStorage(**defaults)


def test_smb_builds_unc_paths():
    storage = _smb()

    assert storage._unc(("rechnungen", "2026"), "beleg.pdf") == (
        "\\\\nas.local\\Belege\\rechnungen\\2026\\beleg.pdf"
    )
    assert storage._unc(()) == "\\\\nas.local\\Belege"


def test_smb_root_prefixes_every_path():
    storage = _smb(root="archiv/2026")

    assert storage._unc(("rechnungen",)) == "\\\\nas.local\\Belege\\archiv\\2026\\rechnungen"
    assert storage.description == "//nas.local/Belege/archiv/2026"


def test_smb_display_uses_forward_slashes():
    assert _smb().display(("rechnungen",), "beleg.pdf") == "//nas.local/Belege/rechnungen/beleg.pdf"


def test_smb_root_cannot_escape_the_share():
    with pytest.raises(ValueError):
        _smb(root="../../etc")


# --- SMB backend: reconnect behaviour -----------------------------------------


def test_smb_retries_once_on_a_failed_call(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) == 1:
            raise OSError(errno.ECONNRESET, "connection reset")
        return "ok"

    assert storage._with_reconnect("write", flaky) == "ok"
    assert len(attempts) == 2


def test_smb_missing_file_is_reported_as_filenotfound_without_retrying(monkeypatch):
    """The mapping file may legitimately not exist - that is not a broken session."""
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    attempts = []

    def missing():
        attempts.append(1)
        raise OSError(errno.ENOENT, "no such file")

    with pytest.raises(FileNotFoundError):
        storage._with_reconnect("stat", missing)
    assert len(attempts) == 1


def test_smb_reraises_when_the_retry_also_fails(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)

    def always_broken():
        raise OSError(errno.EACCES, "permission denied")

    with pytest.raises(OSError, match="permission denied"):
        storage._with_reconnect("write", always_broken)


# --- listing and moving files (pickup folders) --------------------------------


def _drop(path: Path, content: bytes = b"scan") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def test_list_files_finds_files_in_subfolders(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf")
    _drop(tmp_path / "scans" / "anna" / "b.pdf")

    found = storage.list_files(("scans",))

    assert sorted(entry.relative for entry in found) == ["scans/a.pdf", "scans/anna/b.pdf"]
    assert all(entry.size == 4 for entry in found)


def test_list_files_skips_hidden_entries(tmp_path):
    """Our own temporary files start with a dot - they are not documents."""
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / ".mail2nas-tmp-1")
    _drop(tmp_path / "scans" / "real.pdf")

    assert [entry.name for entry in storage.list_files(("scans",))] == ["real.pdf"]


def test_list_files_on_a_missing_folder_is_empty(tmp_path):
    assert LocalStorage(str(tmp_path)).list_files(("gibtsnicht",)) == []


def test_list_files_stops_at_the_depth_limit(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a" / "b" / "c" / "deep.pdf")

    assert storage.list_files(("scans",), max_depth=2) == []
    assert len(storage.list_files(("scans",), max_depth=5)) == 1


def test_move_unique_moves_and_removes_the_original(tmp_path):
    storage = LocalStorage(str(tmp_path))
    source = _drop(tmp_path / "scans" / "a.pdf", b"inhalt")

    out = storage.move_unique(("scans", "a.pdf"), ("eingang",), "2026-01-01_a.pdf")

    assert not source.exists()
    assert Path(out).read_bytes() == b"inhalt"


def test_move_unique_never_overwrites(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "eingang" / "a.pdf", b"alt")
    _drop(tmp_path / "scans" / "a.pdf", b"neu")

    out = storage.move_unique(("scans", "a.pdf"), ("eingang",), "a.pdf")

    assert Path(out).name == "a_1.pdf"
    assert (tmp_path / "eingang" / "a.pdf").read_bytes() == b"alt"


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_a_source_that_cannot_be_deleted_leaves_no_copy(tmp_path):
    """Copying without deleting would re-import the same scan for ever."""
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf")
    (tmp_path / "scans").chmod(0o500)
    try:
        with pytest.raises(OSError):
            storage.move_unique(("scans", "a.pdf"), ("eingang",), "a.pdf")
        assert list((tmp_path / "eingang").glob("*")) == []
    finally:
        (tmp_path / "scans").chmod(0o700)


def test_read_bytes(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf", b"%PDF-1.4")

    assert storage.read_bytes("scans/a.pdf") == b"%PDF-1.4"
MAIL2NAS_EOF

# --- tests/test_web.py ---
cat > tests/test_web.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import re

import pytest

from mail2nas.mapping import Rule
from mail2nas.state import SettingsStore
from mail2nas.web import (
    SETTING_PASSWORD_HASH,
    LoginThrottle,
    create_app,
    ensure_password,
)
from tests.test_archiver import _make_runtime

PASSWORD = "geheim1234"


@pytest.fixture
def env(tmp_path):
    """A configured app plus the storage and settings behind it.

    tmp_path is the (local) default archive, as the UI would set it up.
    """
    runtime = _make_runtime(tmp_path, web_password=PASSWORD)
    settings, config = runtime.settings, runtime.config
    ensure_password(settings, config.web_password)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app, runtime.storage, settings, config, runtime


@pytest.fixture
def client(env):
    app = env[0]
    with app.test_client() as client:
        yield client


def _csrf(client, path="/login") -> str:
    """Fetch a page and pull the CSRF token out of it, like a browser would."""
    html = client.get(path).get_data(as_text=True)
    match = re.search(r'name="csrf_token" value="([^"]+)"', html)
    assert match, f"no CSRF token on {path}"
    return match.group(1)


def _login(client, password=PASSWORD):
    return client.post(
        "/login",
        data={"password": password, "csrf_token": _csrf(client)},
        follow_redirects=False,
    )


# --- authentication -----------------------------------------------------------


def test_mapping_page_requires_login(client):
    response = client.get("/mapping")

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_login_with_correct_password_reaches_the_mapping_page(client):
    assert _login(client).status_code == 302

    page = client.get("/mapping")
    assert page.status_code == 200
    assert "Zuordnungen" in page.get_data(as_text=True)


def test_login_with_wrong_password_is_rejected(client):
    response = client.post(
        "/login", data={"password": "falsch", "csrf_token": _csrf(client)}
    )

    assert response.status_code == 401
    assert client.get("/mapping").status_code == 302


def test_post_without_csrf_token_is_refused(client):
    _login(client)

    response = client.post("/mapping/add", data={"keyword": "RE", "folder": "rechnungen"})

    assert response.status_code == 400


def test_logout_ends_the_session(client):
    _login(client)
    token = _csrf(client, "/mapping")

    client.post("/logout", data={"csrf_token": token})

    assert client.get("/mapping").status_code == 302


def test_healthz_needs_no_login(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_data(as_text=True).strip() == "ok"


def test_security_headers_are_set(client):
    headers = client.get("/login").headers

    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert headers["X-Frame-Options"] == "DENY"


# --- editing the mapping -------------------------------------------------------


def test_adding_a_rule_writes_it_to_the_share(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "Rechnung", "folder": "", "new_folder": "rechnungen",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
        ("Rechnung", "rechnungen")
    ]


def test_a_new_folder_is_created_on_the_share(client, env, tmp_path):
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": "rechnungen/2026",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert (tmp_path / "rechnungen" / "2026").is_dir()


def test_existing_folders_are_offered_for_selection(client, tmp_path):
    (tmp_path / "lieferscheine").mkdir()
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert '<option value="lieferscheine">' in html


def test_duplicate_keyword_is_rejected_case_insensitively(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    response = client.post(
        "/mapping/add",
        data={"keyword": "re", "new_folder": "woanders",
              "csrf_token": _csrf(client, "/mapping")},
        follow_redirects=True,
    )

    assert "gibt es schon" in response.get_data(as_text=True)
    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
        ("RE", "rechnungen")
    ]


@pytest.mark.parametrize("folder", ["../ausbruch", "/etc", ""])
def test_target_folder_cannot_escape_the_archive_root(client, env, folder, tmp_path):
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": folder,
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert runtime.rule_store.load() == []
    assert not (tmp_path.parent / "ausbruch").exists()


def test_changing_the_folder_of_an_existing_rule(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    client.post(
        "/mapping/update",
        data={"index": "0", "folder": "belege", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
        ("RE", "belege")
    ]


def test_deleting_a_rule_keeps_the_others(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    client.post(
        "/mapping/delete",
        data={"index": "0", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [r.keyword for r in runtime.rule_store.load()] == ["LS"]


def test_unreadable_share_does_not_break_the_page(client, env, monkeypatch):
    """A NAS that is briefly away must still render, with an explanation."""
    _, storage, _, _, runtime = env
    _login(client)
    monkeypatch.setattr(
        storage, "list_folders", lambda *a, **k: (_ for _ in ()).throw(OSError("NAS weg"))
    )

    response = client.get("/mapping")

    assert response.status_code == 200
    assert "NAS weg" in response.get_data(as_text=True)


# --- password handling ----------------------------------------------------------


def test_password_can_be_changed_and_the_old_one_stops_working(client, env):
    _, _, settings, _, runtime = env
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert "Passwort geaendert" in response.get_data(as_text=True)
    client.post("/logout", data={"csrf_token": _csrf(client, "/mapping")})
    assert _login(client, PASSWORD).status_code == 401
    assert _login(client, "neuesGeheim1").status_code == 302


def test_wrong_current_password_does_not_change_anything(client, env):
    _, _, settings, _, runtime = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    client.post(
        "/password",
        data={"current": "falsch", "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
    )

    assert settings.get(SETTING_PASSWORD_HASH) == before


@pytest.mark.parametrize(
    "new,confirm,expected",
    [("kurz", "kurz", "mindestens"), ("langgenug1", "andersrum", "ueberein")],
)
def test_weak_or_mistyped_new_password_is_rejected(client, env, new, confirm, expected):
    _, _, settings, _, runtime = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": new, "confirm": confirm,
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert expected in response.get_data(as_text=True)
    assert settings.get(SETTING_PASSWORD_HASH) == before


def test_changing_the_password_logs_other_sessions_out(env):
    """A stolen session cookie must not survive a password change."""
    app = env[0]
    # Two plain clients rather than nested `with` blocks: overlapping request
    # contexts confuse Flask's teardown, and no session inspection is needed.
    first, second = app.test_client(), app.test_client()
    _login(first)
    _login(second)
    assert second.get("/mapping").status_code == 200

    first.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(first, "/password")},
    )

    assert second.get("/mapping").status_code == 302
    assert first.get("/mapping").status_code == 200


def test_password_is_not_stored_in_clear_text(env):
    _, _, settings, _, runtime = env

    stored = settings.get(SETTING_PASSWORD_HASH)

    assert PASSWORD not in stored
    assert stored.startswith("scrypt:") or stored.startswith("pbkdf2:")


def test_stored_password_wins_over_the_configured_one(env):
    """WEB_PASSWORD is the initial value only - a later change must survive restarts."""
    _, _, settings, _, runtime = env
    settings.set(SETTING_PASSWORD_HASH, "scrypt:already-set")

    ensure_password(settings, "eineAndere123")

    assert settings.get(SETTING_PASSWORD_HASH) == "scrypt:already-set"


# --- login throttling -------------------------------------------------------------


def test_throttle_blocks_after_repeated_failures():
    throttle = LoginThrottle(max_failures=3, lockout=60)

    for _ in range(2):
        throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") == 0

    throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") > 0
    assert throttle.seconds_blocked("10.0.0.2") == 0


def test_successful_login_clears_the_throttle():
    throttle = LoginThrottle(max_failures=1, lockout=60)
    throttle.record_failure("10.0.0.1")

    throttle.reset("10.0.0.1")

    assert throttle.seconds_blocked("10.0.0.1") == 0


def test_locked_out_client_is_refused_even_with_the_right_password(client, env):
    for _ in range(6):
        client.post("/login", data={"password": "falsch", "csrf_token": _csrf(client)})

    response = client.post(
        "/login", data={"password": PASSWORD, "csrf_token": _csrf(client)}
    )

    assert response.status_code == 429
    assert client.get("/mapping").status_code == 302


# --- rule order ------------------------------------------------------------------


def _keywords(runtime):
    return [rule.keyword for rule in runtime.rule_store.load()]


def test_moving_a_rule_up_reorders_the_file(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b"), Rule.create("C", "c")])
    _login(client)

    client.post("/mapping/up", data={"index": "2", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "C", "B"]


def test_moving_a_rule_down_reorders_the_file(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/down", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["B", "A"]


def test_moving_the_top_rule_up_is_harmless(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/up", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "B"]


@pytest.mark.parametrize("index", ["7", "-1", "keineZahl"])
def test_a_bogus_row_index_is_refused(client, env, index):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/delete", data={"index": index, "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A"]


def test_new_rules_are_appended_at_the_bottom(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/add", data={"keyword": "B", "new_folder": "b",
                                      "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "B"]


# --- accounts ---------------------------------------------------------------------


def _add_account(runtime, **fields):
    defaults = dict(name="Buchhaltung", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_config_page_lists_the_accounts(client, env):
    _, _, _, _, runtime = env
    _add_account(runtime)
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buchhaltung" in html
    assert "imap.example.com" in html


def test_creating_an_account_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/accounts/new", data={
        "name": "Zweitpostfach", "host": "imap2.example.com", "port": "143",
        "user": "zwei", "password": "geheim", "folder": "INBOX", "mode": "poll",
        "processed_folder": "", "oversized_folder": "", "enabled": "1",
        "csrf_token": _csrf(client, "/config/accounts/new")})

    accounts = runtime.accounts.all()
    assert [a.name for a in accounts] == ["Zweitpostfach"]
    assert accounts[0].port == 143 and accounts[0].ssl is False


def test_editing_an_account_keeps_the_password_when_left_empty(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="altesGeheim")
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Neuer Name", "host": "imap.example.com", "port": "993",
        "user": "u", "password": "", "folder": "INBOX", "mode": "idle",
        "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.password == "altesGeheim"
    assert account.name == "Neuer Name" and account.mode == "idle"


def test_an_invalid_port_is_rejected(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "A", "host": "h", "port": "keinPort", "user": "u", "password": "",
        "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")},
        follow_redirects=True)

    assert "Port" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).host == "imap.example.com"


def test_deleting_an_account(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.accounts.all() == []


def test_a_rule_can_be_bound_to_an_account(client, env):
    _, storage, _, config, runtime = env
    account_id = _add_account(runtime)
    _add_account(runtime, name="Zweites")
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": str(account_id),
        "csrf_token": _csrf(client, "/mapping")})

    assert runtime.rule_store.load()[0].account == str(account_id)


def test_a_rule_cannot_reference_an_unknown_account(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert runtime.rule_store.load() == []


# --- moving the mapping file --------------------------------------------------------


def test_reordering_without_a_csrf_token_is_refused(client, env):
    """The arrows go through a helper, so their CSRF check needs its own test."""
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    response = client.post("/mapping/up", data={"index": "1"})

    assert response.status_code == 400
    assert _keywords(runtime) == ["A", "B"]


def test_the_stored_account_password_is_never_sent_to_the_browser(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="streng-geheim")
    _login(client)

    html = client.get(f"/config/accounts/{account_id}").get_data(as_text=True)

    assert "streng-geheim" not in html


# --- printers -----------------------------------------------------------------------


def _add_printer(runtime, **fields):
    defaults = dict(name="Buero EG", destination="Kyocera_M2540")
    defaults.update(fields)
    return runtime.printers.add(**defaults)


def test_config_page_lists_the_printers(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime, server="cups.lan:631")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buero EG" in html
    assert "Kyocera_M2540" in html
    assert "cups.lan:631" in html


def test_creating_a_printer_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/printers/new", data={
        "name": "Buchhaltung", "destination": "HP_LJ", "server": "", "copies": "2",
        "options": "media=A4 sides=two-sided-long-edge", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")})

    printers = runtime.printers.all()
    assert [(p.name, p.destination, p.copies) for p in printers] == [("Buchhaltung", "HP_LJ", 2)]
    assert printers[0].option_list == ["media=A4", "sides=two-sided-long-edge"]


def test_an_unusable_queue_name_is_rejected_with_a_message(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/printers/new", data={
        "name": "Kaputt", "destination": "zwei woerter", "copies": "1", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")}, follow_redirects=True)

    assert "Leerzeichen" in response.get_data(as_text=True)
    assert runtime.printers.all() == []


def test_editing_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}", data={
        "name": "Buero OG", "destination": "Kyocera_M2540", "copies": "1", "enabled": "",
        "csrf_token": _csrf(client, f"/config/printers/{printer_id}")})

    printer = runtime.printers.get(printer_id)
    assert printer.name == "Buero OG"
    assert printer.enabled is False


def test_deleting_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.printers.all() == []


def test_a_test_print_reports_a_failing_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **k: subprocess.CompletedProcess([], 1, "", "lp: Kein Drucker"),
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testdruck fehlgeschlagen" in response.get_data(as_text=True)


def test_a_test_print_confirms_a_working_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess, "run", lambda *a, **k: subprocess.CompletedProcess([], 0, "request id is q-1", "")
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testseite" in response.get_data(as_text=True)


def test_the_print_settings_of_a_mailbox_are_saved(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.print_attachments is True
    assert account.printer == str(printer_id)
    # the "archive" box was not ticked, so this mailbox prints only
    assert account.archive_attachments is False


def test_a_mailbox_cannot_reference_an_unknown_printer(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": "999",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "Drucker" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).print_attachments is False


def test_a_rule_can_be_set_to_print_on_a_specific_printer(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is True
    assert rule.printer == str(printer_id)


def test_a_rule_can_print_on_the_mailbox_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "account",
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is True
    assert rule.printer == ""


def test_a_rule_cannot_reference_an_unknown_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert runtime.rule_store.load() == []


def test_changing_a_rules_folder_keeps_its_print_settings(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    runtime.mapping.save([Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "belege", "print_fields": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.folder == "belege"
    assert (rule.print_attachments, rule.printer) == (True, str(printer_id))


def test_printing_can_be_switched_off_for_a_rule(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    runtime.mapping.save([Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "rechnungen", "print_fields": "1", "printer": "",
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is False
    assert rule.printer == ""


def test_without_a_printer_the_print_controls_stay_hidden(client, env):
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "nicht drucken" not in html


# --- delivery addresses ------------------------------------------------------


def _add_address(runtime, **fields) -> int:
    values = dict(
        name="Drucker Buero",
        recipient="drucker@firma.de",
        print_attachments=True,
        archive_attachments=True,
    )
    values.update(fields)
    return runtime.addresses.add(**values)


@pytest.mark.parametrize("path", ["/config/addresses/new", "/config/addresses/1"])
def test_address_pages_require_login(client, path):
    response = client.get(path)

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_config_page_lists_the_addresses(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _add_address(runtime, printer=str(printer_id), folder="ausdrucke")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "drucker@firma.de" in html
    assert "ausdrucke" in html
    # the printer is named by its label, not by its bare id
    assert "Buero EG" in html


def test_creating_an_address_through_the_form(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post("/config/addresses/new", data={
        "name": "Drucker Buero", "recipient": "drucker@firma.de", "sender": "@firma.de",
        "print_attachments": "1", "printer": str(printer_id),
        "archive_attachments": "1", "folder": "ausdrucke", "enabled": "1",
        "csrf_token": _csrf(client, "/config/addresses/new")})

    rules = runtime.addresses.all()
    assert [(r.recipient, r.sender, r.printer, r.folder) for r in rules] == [
        ("drucker@firma.de", "@firma.de", str(printer_id), "ausdrucke")
    ]


def test_an_address_without_an_at_sign_is_rejected_with_a_message(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Kaputt", "recipient": "kein-at-zeichen", "print_attachments": "1",
        "archive_attachments": "1", "csrf_token": _csrf(client, "/config/addresses/new")},
        follow_redirects=True)

    assert "@" in response.get_data(as_text=True)
    assert runtime.addresses.all() == []


def test_an_address_that_neither_prints_nor_files_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Weg damit", "recipient": "drucker@firma.de",
        "csrf_token": _csrf(client, "/config/addresses/new")}, follow_redirects=True)

    assert "verworfen" in response.get_data(as_text=True)
    assert runtime.addresses.all() == []


def test_editing_an_address(client, env):
    _, _, _, _, runtime = env
    address_id = _add_address(runtime)
    _login(client)

    client.post(f"/config/addresses/{address_id}", data={
        "name": "Drucker OG", "recipient": "drucker-og@firma.de", "sender": "",
        "print_attachments": "1", "printer": "", "archive_attachments": "1",
        "folder": "", "enabled": "",
        "csrf_token": _csrf(client, f"/config/addresses/{address_id}")})

    rule = runtime.addresses.get(address_id)
    assert (rule.name, rule.recipient, rule.enabled) == ("Drucker OG", "drucker-og@firma.de", False)


def test_deleting_an_address(client, env):
    _, _, _, _, runtime = env
    address_id = _add_address(runtime)
    _login(client)

    client.post(f"/config/addresses/{address_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.addresses.all() == []


def test_opening_a_deleted_address_does_not_500(client, env):
    _login(client)

    response = client.get("/config/addresses/999", follow_redirects=True)

    assert response.status_code == 200
    assert "gibt es nicht mehr" in response.get_data(as_text=True)


def test_deleting_a_printer_unpins_the_addresses_using_it(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    address_id = _add_address(runtime, printer=str(printer_id))
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.addresses.get(address_id).printer == ""


def test_changes_to_addresses_need_a_csrf_token(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Ohne Token", "recipient": "drucker@firma.de", "print_attachments": "1"})

    assert response.status_code == 400
    assert runtime.addresses.all() == []


# --- finding printers on the network -----------------------------------------


def test_the_discovery_page_needs_login(client):
    response = client.get("/config/printers/discover")

    assert response.status_code == 302


def test_the_discovery_page_offers_the_configured_cups_server(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime, server="cups.lan:631")
    _login(client)

    html = client.get("/config/printers/discover").get_data(as_text=True)

    assert 'value="cups.lan:631"' in html


def test_searching_lists_what_was_found(client, env, monkeypatch):
    from mail2nas import web as web_module
    from mail2nas.discovery import Found

    monkeypatch.setattr(
        web_module,
        "discover",
        lambda server, **kwargs: (
            [
                Found("Buero_MFP", "Buero_MFP", "cups.lan", "cups", "ipp://10.0.0.5/ipp/print"),
                Found("Kyocera M2540", "ipp/print", "10.0.0.6", "mdns", "ipp://10.0.0.6/ipp/print"),
            ],
            [],
        ),
    )
    _login(client)

    html = client.post(
        "/config/printers/discover",
        data={"server": "cups.lan", "csrf_token": _csrf(client, "/config/printers/discover")},
    ).get_data(as_text=True)

    assert "Buero_MFP" in html
    assert "Kyocera M2540" in html
    # the device without a queue comes with the command that creates one
    assert "lpadmin -p Kyocera_M2540" in html


def test_a_failing_search_reports_instead_of_crashing(client, env, monkeypatch):
    from mail2nas import web as web_module

    def boom(*args, **kwargs):
        raise OSError("kaputt")

    monkeypatch.setattr(web_module, "discover", boom)
    _login(client)

    response = client.post(
        "/config/printers/discover",
        data={"csrf_token": _csrf(client, "/config/printers/discover")},
    )

    assert response.status_code == 200
    assert "kaputt" in response.get_data(as_text=True)


def test_taking_over_a_found_printer_prefills_the_form(client, env):
    _login(client)

    html = client.get(
        "/config/printers/new?name=Kyocera&destination=ipp%2Fprint&server=10.0.0.6"
    ).get_data(as_text=True)

    assert 'value="Kyocera"' in html
    assert 'value="ipp/print"' in html
    assert 'value="10.0.0.6"' in html
    # nothing is stored yet, so there is nothing to test-print or delete
    assert "Testseite drucken" not in html


# --- archives -----------------------------------------------------------------


def _add_archive(runtime, **fields) -> int:
    values = dict(name="NAS 2", backend="local", path="/mnt/nas2")
    values.update(fields)
    return runtime.archives.add(**values)


@pytest.mark.parametrize("path", ["/config/archives/new", "/config/archives/1"])
def test_archive_pages_require_login(client, path):
    assert client.get(path).status_code == 302


def test_config_page_lists_the_archives(client, env):
    _, _, _, _, runtime = env
    _add_archive(runtime, name="NAS Buero", backend="smb", host="nas.lan", share="Belege",
                 user="u", password="p")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "NAS Buero" in html
    assert "//nas.lan/Belege" in html


def test_creating_an_archive_through_the_form(client, env, tmp_path):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/archives/new", data={
        "name": "NAS 2", "backend": "local", "path": str(tmp_path / "zwei"), "enabled": "1",
        "csrf_token": _csrf(client, "/config/archives/new")})

    assert [(a.name, a.path) for a in runtime.archives.all()][1:] == [
        ("NAS 2", str(tmp_path / "zwei"))
    ]


def test_an_smb_archive_without_credentials_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/archives/new", data={
        "name": "Kaputt", "backend": "smb", "host": "nas.lan", "share": "Belege",
        "csrf_token": _csrf(client, "/config/archives/new")}, follow_redirects=True)

    assert "Benutzer" in response.get_data(as_text=True)
    assert [a.name for a in runtime.archives.all()] == ["Test"]


def test_editing_an_archive_keeps_the_password_when_left_empty(client, env):
    _, _, _, _, runtime = env
    archive_id = _add_archive(runtime, backend="smb", host="nas.lan", share="Belege",
                              user="u", password="geheim", path="")
    _login(client)

    client.post(f"/config/archives/{archive_id}", data={
        "name": "NAS umbenannt", "backend": "smb", "host": "nas.lan", "share": "Belege",
        "user": "u", "password": "", "port": "445", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/archives/{archive_id}")})

    archive = runtime.archives.get(archive_id)
    assert (archive.name, archive.password) == ("NAS umbenannt", "geheim")


def test_testing_an_archive_reports_success(client, env, tmp_path):
    _, _, _, _, runtime = env
    target = tmp_path / "erreichbar"
    target.mkdir()
    archive_id = _add_archive(runtime, path=str(target))
    _login(client)

    response = client.post(f"/config/archives/{archive_id}/test", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert "erreichbar und beschreibbar" in response.get_data(as_text=True)


def test_testing_an_unreachable_archive_reports_the_reason(client, env, tmp_path):
    _, _, _, _, runtime = env
    archive_id = _add_archive(runtime, path=str(tmp_path / "nicht-gemountet"))
    _login(client)

    response = client.post(f"/config/archives/{archive_id}/test", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert "Nicht erreichbar" in response.get_data(as_text=True)


def test_the_last_archive_cannot_be_deleted(client, env):
    _, _, _, _, runtime = env
    archive_id = runtime.archives.all()[0].id
    _login(client)

    client.post(f"/config/archives/{archive_id}/delete", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert len(runtime.archives.all()) == 1


def test_deleting_an_archive(client, env):
    _, _, _, _, runtime = env
    _add_archive(runtime, name="Haupt")
    second = _add_archive(runtime, name="NAS 2")
    _login(client)

    client.post(f"/config/archives/{second}/delete", data={"csrf_token": _csrf(client, "/config")})

    assert [a.name for a in runtime.archives.all()] == ["Test", "Haupt"]


def test_a_rule_can_name_an_archive(client, env, tmp_path):
    _, storage, _, config, runtime = env
    _add_archive(runtime, name="Haupt", path=str(tmp_path))
    second = _add_archive(runtime, name="NAS 2", path=str(tmp_path / "zwei"))
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Vertrag", "folder": "", "new_folder": "vertraege", "archive": str(second),
        "csrf_token": _csrf(client, "/mapping")})

    rules = runtime.rule_store.load()
    assert [(r.keyword, r.archive) for r in rules] == [("Vertrag", str(second))]


def test_a_rule_cannot_name_an_archive_that_does_not_exist(client, env, config=None):
    _, storage, _, config, runtime = env
    _add_archive(runtime)
    _login(client)

    response = client.post("/mapping/add", data={
        "keyword": "Vertrag", "folder": "", "new_folder": "vertraege", "archive": "999",
        "csrf_token": _csrf(client, "/mapping")}, follow_redirects=True)

    assert "Archiv" in response.get_data(as_text=True)
    assert runtime.rule_store.load() == []


# --- pickup folders ------------------------------------------------------------


def test_creating_a_pickup_folder(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/pickups/new", data={
        "name": "Kopierer Flur", "folder": "scans/flur", "target_folder": "eingang",
        "enabled": "1", "csrf_token": _csrf(client, "/config/pickups/new")})

    pickups = runtime.pickups.all()
    assert [(p.name, p.folder, p.target_folder) for p in pickups] == [
        ("Kopierer Flur", "scans/flur", "eingang")
    ]


def test_a_pickup_target_inside_its_own_folder_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/pickups/new", data={
        "name": "Schleife", "folder": "scans", "target_folder": "scans/fertig",
        "enabled": "1", "csrf_token": _csrf(client, "/config/pickups/new")},
        follow_redirects=True)

    assert "immer wieder eingelesen" in response.get_data(as_text=True)
    assert runtime.pickups.all() == []


def test_config_page_lists_the_pickup_folders(client, env):
    _, _, _, _, runtime = env
    runtime.pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Kopierer" in html
    assert "scans" in html


def test_editing_and_deleting_a_pickup_folder(client, env):
    _, _, _, _, runtime = env
    pickup_id = runtime.pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _login(client)

    client.post(f"/config/pickups/{pickup_id}", data={
        "name": "Kopierer OG", "folder": "scans", "target_folder": "eingang", "enabled": "",
        "csrf_token": _csrf(client, f"/config/pickups/{pickup_id}")})
    assert runtime.pickups.get(pickup_id).enabled is False

    client.post(f"/config/pickups/{pickup_id}/delete", data={"csrf_token": _csrf(client, "/config")})
    assert runtime.pickups.all() == []


def test_deleting_a_printer_stops_the_pickups_printing(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    pickup_id = runtime.pickups.add(
        name="Kopierer", folder="scans", print_attachments=True, printer=str(printer_id)
    )
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete", data={"csrf_token": _csrf(client, "/config")})

    pickup = runtime.pickups.get(pickup_id)
    assert (pickup.print_attachments, pickup.printer) == (False, "")


# --- quarantine list and pickup timing ------------------------------------------




# --- the first password is generated, not required -------------------------------


def test_without_any_password_a_random_one_is_generated(tmp_path):
    from mail2nas.web import read_initial_password

    settings = SettingsStore(str(tmp_path / "state.db"))

    generated = ensure_password(settings, "", str(tmp_path))

    assert generated and len(generated) >= 16
    assert read_initial_password(str(tmp_path)) == generated
    assert oct((tmp_path / "initial-password.txt").stat().st_mode & 0o777) == "0o600"
    assert settings.get(SETTING_PASSWORD_HASH)


def test_a_too_short_old_password_is_replaced_by_a_random_one(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    assert ensure_password(settings, "kurz", str(tmp_path)) is not None


def test_changing_the_password_removes_the_generated_one(tmp_path):
    from mail2nas.web import read_initial_password

    runtime = _make_runtime(tmp_path)
    generated = ensure_password(runtime.settings, "", runtime.config.data_dir)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    with app.test_client() as client:
        _login(client, generated)
        client.post("/password", data={
            "current": generated, "new": "meinEigenes1", "confirm": "meinEigenes1",
            "csrf_token": _csrf(client, "/password")})

    assert read_initial_password(runtime.config.data_dir) is None


# --- overview and first-time setup ----------------------------------------------


def _fresh_client(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    ensure_password(runtime.settings, PASSWORD)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app.test_client(), runtime


def test_after_login_the_overview_is_shown(client):
    response = _login(client)

    assert response.headers["Location"].endswith("/overview")


def test_a_fresh_installation_is_walked_through_the_setup(tmp_path):
    client, _ = _fresh_client(tmp_path)
    _login(client)

    html = client.get("/overview").get_data(as_text=True)

    assert "Einrichtung" in html
    assert "Archiv einrichten" in html
    assert "Postfach anlegen" in html


def test_every_page_says_that_no_archive_exists_yet(tmp_path):
    client, _ = _fresh_client(tmp_path)
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "Noch kein Archiv eingerichtet" in html


def test_the_overview_shows_the_archive_status(client, env):
    _, _, _, _, runtime = env
    runtime.status.archive.ok = False
    runtime.status.archive.detail = "Zugriff verweigert"
    _login(client)

    html = client.get("/overview").get_data(as_text=True)

    assert "Zugriff verweigert" in html
    assert "nicht bereit" in html


def test_a_rule_can_be_added_before_any_archive_exists(tmp_path):
    """The folder is created with the first attachment; the rule must not be lost."""
    client, runtime = _fresh_client(tmp_path)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen",
        "csrf_token": _csrf(client, "/mapping")})

    assert [r.keyword for r in runtime.rule_store.load()] == ["Rechnung"]


# --- the settings page --------------------------------------------------------------


def _settings_form(**overrides):
    form = {
        "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
        "filename_prefix": "date_sender", "poll_interval": "300",
        "max_attachment_size_mb": "25", "max_message_size_mb": "50",
        "max_attachments_per_message": "20", "blocked_extensions": "exe, js",
        "pickup_min_age": "20", "printing_enabled": "1", "print_timeout": "120",
        "printable_extensions": "pdf",
    }
    form.update(overrides)
    return form


def test_the_settings_are_saved_and_take_effect_at_once(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/settings", data={
        **_settings_form(fallback_folder="sonstiges", poll_interval="60", match_body="1",
                         blocked_extensions=".EXE, bat; com"),
        "csrf_token": _csrf(client, "/settings")})

    options = runtime.options
    assert options.fallback_folder == "sonstiges"
    assert options.poll_interval == 60
    assert options.match_body is True
    assert options.blocked_extensions == {"exe", "bat", "com"}
    assert runtime.mapping.resolve("Newsletter")[0] == "sonstiges"


def test_settings_survive_a_restart(client, env, tmp_path):
    _, _, _, _, runtime = env
    _login(client)
    client.post("/settings", data={
        **_settings_form(quarantine_folder="gesperrt"), "csrf_token": _csrf(client, "/settings")})

    from mail2nas.options import OptionsStore

    assert OptionsStore(SettingsStore(str(tmp_path / "state.db"))).load().quarantine_folder == "gesperrt"


@pytest.mark.parametrize(
    "field,value,message",
    [
        ("poll_interval", "sofort", "ganze Zahl"),
        ("poll_interval", "1", "zwischen"),
        ("fallback_folder", "../ausbruch", "Ordner"),
        ("quarantine_folder", "unsorted", "verschieden"),
    ],
)
def test_unusable_settings_are_refused_and_nothing_changes(client, env, field, value, message):
    _, _, _, _, runtime = env
    before = runtime.options
    _login(client)

    response = client.post("/settings", data={
        **_settings_form(**{field: value}), "csrf_token": _csrf(client, "/settings")},
        follow_redirects=True)

    assert message in response.get_data(as_text=True)
    assert runtime.options == before


def test_emptying_the_quarantine_list_warns(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/settings", data={
        **_settings_form(blocked_extensions=""), "csrf_token": _csrf(client, "/settings")},
        follow_redirects=True)

    assert "Achtung" in response.get_data(as_text=True)
    assert runtime.blocked_extensions == frozenset()


def test_settings_changes_need_a_csrf_token(client):
    _login(client)

    assert client.post("/settings", data=_settings_form()).status_code == 400


# --- export and import of the rules ---------------------------------------------


def test_the_rules_can_be_exported(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    response = client.get("/mapping/export")

    assert response.headers["Content-Disposition"].startswith("attachment")
    assert "keyword: RE" in response.get_data(as_text=True)


def _upload(client, text, mode="append"):
    import io

    return client.post("/mapping/import", data={
        "mode": mode, "csrf_token": _csrf(client, "/mapping"),
        "rules_file": (io.BytesIO(text.encode("utf-8")), "mapping.yaml"),
    }, content_type="multipart/form-data", follow_redirects=True)


def test_an_old_mapping_file_can_be_imported(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    response = _upload(client, "re: doppelt\nLieferschein: lieferscheine\n")

    assert [r.keyword for r in runtime.rule_store.load()] == ["RE", "Lieferschein"]
    assert "uebersprungen" in response.get_data(as_text=True)


def test_importing_can_replace_the_rules(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("ALT", "alt")])
    _login(client)

    _upload(client, "NEU: neu\n", mode="replace")

    assert [r.keyword for r in runtime.rule_store.load()] == ["NEU"]


def test_an_import_with_an_unsafe_folder_changes_nothing(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("ALT", "alt")])
    _login(client)

    response = _upload(client, "RE: ../../etc\n")

    assert "Import abgebrochen" in response.get_data(as_text=True)
    assert [r.keyword for r in runtime.rule_store.load()] == ["ALT"]


def test_references_that_do_not_exist_here_are_reset_on_import(client, env):
    _, _, _, _, runtime = env
    _login(client)

    _upload(client, "version: 2\nrules:\n- keyword: RE\n  folder: r\n  account: '77'\n"
                    "  printer: '5'\n  print: true\n  archive: '9'\n")

    rule = runtime.rule_store.load()[0]
    assert (rule.account, rule.printer, rule.archive) == ("all", "", "")


def test_the_migration_note_is_shown_once_and_can_be_dismissed(client, env):
    from mail2nas.migrate import SETTING_RULES_NOTE

    _, _, settings, _, _ = env
    settings.set(SETTING_RULES_NOTE, "3 Zuordnung(en) aus mapping.yaml uebernommen.")
    _login(client)

    assert "uebernommen" in client.get("/mapping").get_data(as_text=True)
    client.post("/mapping/note/dismiss", data={"csrf_token": _csrf(client, "/mapping")})
    assert "uebernommen" not in client.get("/mapping").get_data(as_text=True)


# --- testing a mailbox ----------------------------------------------------------------


def test_a_mailbox_can_be_tested_from_the_ui(client, env, monkeypatch):
    from mail2nas import web as web_module

    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    monkeypatch.setattr(web_module, "test_imap", lambda account: 3)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}/test", data={
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "3 ungelesene" in response.get_data(as_text=True)


def test_a_failing_mailbox_test_says_why(client, env, monkeypatch):
    from mail2nas import web as web_module

    _, _, _, _, runtime = env
    account_id = _add_account(runtime)

    def refuse(account):
        raise OSError("AUTHENTICATIONFAILED")

    monkeypatch.setattr(web_module, "test_imap", refuse)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}/test", data={
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "AUTHENTICATIONFAILED" in response.get_data(as_text=True)
MAIL2NAS_EOF

# --- tests/test_accounts.py ---
cat > tests/test_accounts.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.accounts import SETTING_ACCOUNTS_SEEDED, AccountStore, seed_from_config
from mail2nas.state import SettingsStore
from tests.test_archiver import _seed_config


@pytest.fixture
def store(tmp_path):
    return AccountStore(str(tmp_path / "state.db"))


def test_add_and_read_back_an_account(store):
    account_id = store.add(name="Buchhaltung", host="imap.example.com", user="u", password="p")

    account = store.get(account_id)

    assert account.name == "Buchhaltung"
    assert account.port == 993 and account.ssl is True
    assert account.folder == "INBOX" and account.enabled is True
    assert account.key == str(account_id)


def test_update_changes_only_what_is_passed(store):
    account_id = store.add(name="A", host="h", user="u", password="p", folder="Archiv")

    store.update(account_id, name="B")

    account = store.get(account_id)
    assert account.name == "B"
    assert account.folder == "Archiv" and account.password == "p"


def test_disabled_accounts_are_not_watched(store):
    store.add(name="An", host="h", user="u", password="p")
    store.add(name="Aus", host="h", user="u", password="p", enabled=False)

    assert [a.name for a in store.enabled()] == ["An"]
    assert len(store.all()) == 2


def test_delete_removes_the_account(store):
    account_id = store.add(name="A", host="h", user="u", password="p")

    store.delete(account_id)

    assert store.get(account_id) is None


def test_an_unknown_mode_falls_back_to_polling(store):
    account_id = store.add(name="A", host="h", user="u", password="p", mode="bogus")

    assert store.get(account_id).mode == "poll"


def test_fingerprint_changes_when_settings_change(store):
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, password="neu")

    assert store.get(account_id).fingerprint() != before


def test_renaming_does_not_restart_the_worker(store):
    """The name is cosmetic - changing it must not drop an IMAP connection."""
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, name="Anders")

    assert store.get(account_id).fingerprint() == before


# --- seeding from the environment ------------------------------------------------


def test_the_first_account_is_created_from_the_configuration(tmp_path):
    config = _seed_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    accounts = store.all()
    assert len(accounts) == 1
    assert accounts[0].host == config.imap_host
    assert accounts[0].user == config.imap_user


def test_seeding_happens_only_once(tmp_path):
    config = _seed_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)

    seed_from_config(store, settings, config)

    assert len(store.all()) == 1


def test_deleting_the_last_account_does_not_resurrect_it_from_the_env(tmp_path):
    """Otherwise removing a mailbox in the UI would silently come back."""
    config = _seed_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []
    assert settings.get(SETTING_ACCOUNTS_SEEDED) == "1"


def test_a_fresh_installation_gets_no_mailbox_from_the_env(tmp_path):
    """Without IMAP_* in the .env the mailbox is set up in the web UI."""
    config = _seed_config(tmp_path, imap_host="", imap_user="", imap_password="")
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    assert store.all() == []
    assert settings.get(SETTING_ACCOUNTS_SEEDED) == "1"
MAIL2NAS_EOF

# --- tests/test_addresses.py ---
cat > tests/test_addresses.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.addresses import AddressError, AddressRule, AddressStore, matches_address


def _store(tmp_path) -> AddressStore:
    return AddressStore(str(tmp_path / "state.db"))


def _rule(**overrides) -> AddressRule:
    values = dict(
        id=1,
        name="Drucker Buero",
        recipient="drucker@firma.de",
        sender="",
        print_attachments=True,
        printer="",
        archive_attachments=True,
        folder="",
        archive="",
        enabled=True,
    )
    values.update(overrides)
    return AddressRule(**values)


# --- address patterns --------------------------------------------------------


@pytest.mark.parametrize(
    "pattern,address,expected",
    [
        ("drucker@firma.de", "drucker@firma.de", True),
        ("drucker@firma.de", "DRUCKER@Firma.DE", True),
        ("drucker@firma.de", "chef@firma.de", False),
        ("@firma.de", "irgendwer@firma.de", True),
        ("@firma.de", "jemand@fremd.de", False),
        ("@firma.de", "jemand@subfirma.de", False),
        ("drucker-*@firma.de", "drucker-eg@firma.de", True),
        ("drucker-*@firma.de", "buchhaltung@firma.de", False),
        ("drucker-??@firma.de", "drucker-eg@firma.de", True),
        ("drucker-??@firma.de", "drucker-erdgeschoss@firma.de", False),
        ("", "drucker@firma.de", False),
        ("drucker@firma.de", "", False),
    ],
)
def test_matches_address(pattern, address, expected):
    assert matches_address(pattern, address) is expected


def test_a_pattern_with_absurdly_many_wildcards_is_ignored():
    """Matching cost is bounded: the text comes from outside."""
    assert matches_address("a*a*a*a*a*a*a*@firma.de", "aaaaaaaa@firma.de") is False


# --- rule matching -----------------------------------------------------------


def test_recipient_only_rule_ignores_the_sender():
    rule = _rule(recipient="drucker@firma.de")

    assert rule.matches(["drucker@firma.de"], "fremder@example.com") is True


def test_any_of_the_recipients_may_match():
    """A mail to several people still counts as addressed to the printer."""
    rule = _rule(recipient="drucker@firma.de")

    assert rule.matches(["chef@firma.de", "drucker@firma.de"], "a@b.c") is True


def test_sender_only_rule_matches_by_sender():
    rule = _rule(recipient="", sender="scanner@firma.de")

    assert rule.matches(["archiv@firma.de"], "scanner@firma.de") is True


def test_both_patterns_have_to_match():
    """The sender restricts who may print, it is not a second trigger."""
    rule = _rule(recipient="drucker@firma.de", sender="@firma.de")

    assert rule.matches(["drucker@firma.de"], "kollege@firma.de") is True
    assert rule.matches(["drucker@firma.de"], "fremder@example.com") is False
    assert rule.matches(["anderes@firma.de"], "kollege@firma.de") is False


def test_a_rule_without_any_pattern_never_matches():
    """Belt and braces for a hand-edited database: never print everything."""
    rule = _rule(recipient="", sender="")

    assert rule.matches(["drucker@firma.de"], "chef@firma.de") is False


# --- store -------------------------------------------------------------------


def test_add_and_read_back(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(
        name="Buero", recipient="drucker@firma.de", print_attachments=True, printer="3"
    )

    stored = store.get(rule_id)
    assert (stored.recipient, stored.printer, stored.print_attachments) == (
        "drucker@firma.de",
        "3",
        True,
    )


def test_update_keeps_the_fields_not_sent(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(name="Buero", recipient="drucker@firma.de", folder="ausdrucke")

    store.update(rule_id, name="Buero EG")

    stored = store.get(rule_id)
    assert (stored.name, stored.folder) == ("Buero EG", "ausdrucke")


def test_delete(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(recipient="drucker@firma.de")

    store.delete(rule_id)

    assert store.get(rule_id) is None


def test_first_matching_rule_wins(tmp_path):
    """Two aliases covering one mail must not print it twice."""
    store = _store(tmp_path)
    store.add(name="Speziell", recipient="drucker-eg@firma.de")
    store.add(name="Allgemein", recipient="@firma.de")

    assert store.match(["drucker-eg@firma.de"], "chef@firma.de").name == "Speziell"


def test_disabled_rules_are_skipped(tmp_path):
    store = _store(tmp_path)
    store.add(name="Aus", recipient="drucker@firma.de", enabled=False)

    assert store.match(["drucker@firma.de"], "chef@firma.de") is None


def test_no_match_returns_none(tmp_path):
    store = _store(tmp_path)
    store.add(recipient="drucker@firma.de")

    assert store.match(["archiv@firma.de"], "chef@firma.de") is None


def test_deleting_a_printer_unpins_the_rules_using_it(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(recipient="drucker@firma.de", print_attachments=True, printer="7")
    store.add(recipient="anderes@firma.de", print_attachments=True, printer="8")

    assert store.clear_printer("7") == 1

    assert store.get(rule_id).printer == ""


def test_the_table_survives_a_second_open(tmp_path):
    store = _store(tmp_path)
    store.add(recipient="drucker@firma.de")

    assert len(AddressStore(str(tmp_path / "state.db")).all()) == 1


# --- validation --------------------------------------------------------------


def test_an_entry_without_any_address_is_rejected(tmp_path):
    with pytest.raises(AddressError, match="Empfaengeradresse"):
        _store(tmp_path).add(name="Leer")


@pytest.mark.parametrize(
    "pattern", ["kein-at-zeichen", "zwei@adressen.de, noch@eine.de", "mit leerzeichen@firma.de"]
)
def test_unusable_recipient_patterns_are_rejected(tmp_path, pattern):
    with pytest.raises(AddressError):
        _store(tmp_path).add(recipient=pattern)


def test_neither_printing_nor_filing_is_rejected(tmp_path):
    """That combination would silently throw the attachment away."""
    with pytest.raises(AddressError, match="verworfen"):
        _store(tmp_path).add(
            recipient="drucker@firma.de", print_attachments=False, archive_attachments=False
        )


def test_a_folder_that_escapes_the_archive_is_rejected(tmp_path):
    with pytest.raises(AddressError, match="Zielordner"):
        _store(tmp_path).add(recipient="drucker@firma.de", folder="../woanders")


def test_the_address_is_normalised(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(recipient="  Drucker@Firma.DE  ", folder="ausdrucke/2026/")

    stored = store.get(rule_id)
    assert stored.recipient == "drucker@firma.de"
    assert stored.folder == "ausdrucke/2026"


def test_the_name_defaults_to_the_address(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(recipient="drucker@firma.de")

    assert store.get(rule_id).name == "drucker@firma.de"


def test_an_older_database_gets_the_archive_column(tmp_path):
    """Updating must not mean re-entering every delivery address."""
    import sqlite3

    db = str(tmp_path / "state.db")
    with sqlite3.connect(db) as conn:
        # Exactly the table the previous version created.
        conn.execute(
            "CREATE TABLE address_rules ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, "
            "recipient TEXT NOT NULL DEFAULT '', sender TEXT NOT NULL DEFAULT '', "
            "print_attachments INTEGER NOT NULL DEFAULT 1, printer TEXT NOT NULL DEFAULT '', "
            "archive_attachments INTEGER NOT NULL DEFAULT 1, folder TEXT NOT NULL DEFAULT '', "
            "enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute(
            "INSERT INTO address_rules (name, recipient, printer) VALUES ('Alt', 'a@b.de', '2')"
        )

    store = AddressStore(db)

    rule = store.all()[0]
    assert (rule.name, rule.recipient, rule.printer) == ("Alt", "a@b.de", "2")
    assert rule.archive == ""  # the archive it always used: the default one
MAIL2NAS_EOF

# --- tests/test_archives.py ---
cat > tests/test_archives.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.archives import (
    Archive,
    ArchiveError,
    ArchiveStore,
    StorageSet,
    seed_from_config,
)
from mail2nas.state import SettingsStore
from mail2nas.storage import LocalStorage, SmbStorage
from tests.test_archiver import _seed_config


def _store(tmp_path) -> ArchiveStore:
    return ArchiveStore(str(tmp_path / "state.db"))


def _local(tmp_path, **fields) -> int:
    values = dict(name="Haupt", backend="local", path=str(tmp_path))
    values.update(fields)
    return _store(tmp_path).add(**values)


# --- validation ---------------------------------------------------------------


def test_an_smb_archive_needs_server_share_and_credentials(tmp_path):
    store = _store(tmp_path)

    for missing in ("host", "share", "user", "password"):
        fields = dict(
            name="NAS", backend="smb", host="nas.lan", share="Belege", user="u", password="p"
        )
        fields[missing] = ""
        with pytest.raises(ArchiveError):
            store.add(**fields)


def test_a_mounted_archive_needs_an_absolute_path(tmp_path):
    store = _store(tmp_path)

    with pytest.raises(ArchiveError, match="absoluter Pfad"):
        store.add(name="Lokal", backend="local", path="relativ/pfad")


def test_an_unknown_backend_is_rejected(tmp_path):
    with pytest.raises(ArchiveError, match="Unbekannte Art"):
        _store(tmp_path).add(name="X", backend="ftp", path="/mnt/x")


def test_a_subfolder_that_escapes_the_share_is_rejected(tmp_path):
    with pytest.raises(ArchiveError, match="Unterordner"):
        _store(tmp_path).add(
            name="NAS", backend="smb", host="h", share="s", user="u", password="p",
            root="../woanders",
        )


def test_the_port_has_to_be_a_number(tmp_path):
    with pytest.raises(ArchiveError, match="Zahl"):
        _store(tmp_path).add(
            name="NAS", backend="smb", host="h", share="s", user="u", password="p", port="vier",
        )


def test_the_name_defaults_to_the_share(tmp_path):
    store = _store(tmp_path)

    archive_id = store.add(
        backend="smb", host="nas.lan", share="Belege", user="u", password="p"
    )

    assert store.get(archive_id).name == "Belege"


# --- store --------------------------------------------------------------------


def test_add_and_read_back(tmp_path):
    store = _store(tmp_path)

    archive_id = store.add(
        name="NAS Buero", backend="smb", host="nas.lan", share="Belege",
        user="archiv", password="geheim", root="2026", port=445, encrypt=False,
    )

    archive = store.get(archive_id)
    assert archive.location() == "//nas.lan/Belege/2026"
    assert archive.encrypt is False
    assert archive.key == str(archive_id)


def test_update_keeps_the_fields_not_sent(tmp_path):
    store = _store(tmp_path)
    archive_id = store.add(
        name="NAS", backend="smb", host="nas.lan", share="Belege", user="u", password="geheim"
    )

    store.update(archive_id, name="NAS Buero")

    archive = store.get(archive_id)
    assert (archive.name, archive.password) == ("NAS Buero", "geheim")


def test_the_default_is_the_first_enabled_archive(tmp_path):
    store = _store(tmp_path)
    first = store.add(name="Alt", backend="local", path="/mnt/alt", enabled=False)
    second = store.add(name="Neu", backend="local", path="/mnt/neu")

    assert store.default().id == second
    assert store.get(first).enabled is False


def test_by_key_survives_nonsense(tmp_path):
    store = _store(tmp_path)

    assert store.by_key("keine-zahl") is None
    assert store.by_key("999") is None


# --- seeding from the environment ---------------------------------------------


def test_seeding_takes_the_smb_settings_from_the_env(tmp_path):
    config = _seed_config(
        tmp_path, storage_backend="smb", smb_host="nas.lan", smb_share="Belege",
        smb_user="archiv", smb_password="geheim",
    )
    store = _store(tmp_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    archive = store.default()
    assert (archive.backend, archive.host, archive.share) == ("smb", "nas.lan", "Belege")


def test_seeding_takes_the_mounted_directory_from_the_env(tmp_path):
    config = _seed_config(tmp_path, storage_backend="local")
    store = _store(tmp_path)

    seed_from_config(store, SettingsStore(config.state_db_path), config)

    archive = store.default()
    assert (archive.backend, archive.path) == ("local", config.storage_root)


def test_seeding_happens_only_once(tmp_path):
    """Deleting the last archive in the UI must not resurrect it on restart."""
    config = _seed_config(tmp_path, storage_backend="local")
    store = _store(tmp_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)

    for archive in store.all():
        store.delete(archive.id)
    seed_from_config(store, settings, config)

    assert store.all() == []


def test_a_fresh_installation_gets_no_archive_from_the_env(tmp_path):
    config = _seed_config(tmp_path, storage_backend="")
    store = _store(tmp_path)

    seed_from_config(store, SettingsStore(config.state_db_path), config)

    assert store.all() == []


def test_an_incomplete_smb_archive_is_not_taken_over(tmp_path):
    """Better no archive (the UI says so) than one that can never connect."""
    config = _seed_config(tmp_path, storage_backend="smb", smb_host="nas", smb_share="x")
    store = _store(tmp_path)

    seed_from_config(store, SettingsStore(config.state_db_path), config)

    assert store.all() == []


# --- storage set --------------------------------------------------------------


def test_without_archives_everything_uses_the_env_storage(tmp_path):
    fallback = LocalStorage(str(tmp_path))
    storages = StorageSet(None, fallback)

    assert storages.get("") is fallback
    assert storages.get("7") is fallback


def test_a_named_archive_gets_its_own_storage(tmp_path):
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    second = store.add(name="NAS 2", backend="local", path=str(tmp_path / "zwei"))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    assert storages.get(str(second)).description == str(tmp_path / "zwei")
    assert storages.default().description == str(tmp_path)


def test_the_storage_is_reused_until_the_archive_changes(tmp_path):
    """An SMB session per attachment would be absurd - so it is cached."""
    store = _store(tmp_path)
    archive_id = store.add(name="Haupt", backend="local", path=str(tmp_path))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    first = storages.get(str(archive_id))
    assert storages.get(str(archive_id)) is first

    store.update(archive_id, path=str(tmp_path / "woanders"))
    rebuilt = storages.get(str(archive_id))

    assert rebuilt is not first
    assert rebuilt.description == str(tmp_path / "woanders")


def test_an_unknown_or_paused_archive_falls_back_to_the_default(tmp_path):
    """A rule may name an archive that was deleted - file it, do not lose it."""
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    paused = store.add(name="Aus", backend="local", path=str(tmp_path / "aus"), enabled=False)
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    assert storages.get("999").description == str(tmp_path)
    assert storages.get(str(paused)).description == str(tmp_path)


def test_an_smb_archive_builds_an_smb_storage(tmp_path):
    archive = Archive(
        id=1, name="NAS", backend="smb", host="nas.lan", share="Belege", user="u",
        password="p", domain="", port=445, root="", encrypt=True, path="", enabled=True,
    )

    assert isinstance(archive.to_storage(), SmbStorage)


def test_closing_releases_every_connection(tmp_path):
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))
    storages.default()

    storages.close()  # must not raise, and drops the cache

    assert storages.default() is not None
MAIL2NAS_EOF

# --- tests/test_pickups.py ---
cat > tests/test_pickups.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.pickups import Pickup, PickupError, PickupStore


def _store(tmp_path) -> PickupStore:
    return PickupStore(str(tmp_path / "state.db"))


def _pickup(**overrides) -> Pickup:
    values = dict(
        id=1,
        name="Kopierer",
        archive="",
        folder="scans",
        target_archive="",
        target_folder="eingang",
        print_attachments=False,
        printer="",
        enabled=True,
    )
    values.update(overrides)
    return Pickup(**values)


# --- validation ---------------------------------------------------------------


def test_a_folder_is_required(tmp_path):
    with pytest.raises(PickupError, match="Ordner"):
        _store(tmp_path).add(name="Ohne Ordner")


@pytest.mark.parametrize("folder", ["../woanders", "/etc", ""])
def test_a_folder_that_escapes_the_archive_is_rejected(tmp_path, folder):
    with pytest.raises(PickupError):
        _store(tmp_path).add(name="Boese", folder=folder)


def test_a_target_inside_the_pickup_folder_is_refused(tmp_path):
    """Otherwise the same document is imported again on every cycle."""
    with pytest.raises(PickupError, match="immer wieder eingelesen"):
        _store(tmp_path).add(name="Schleife", folder="scans", target_folder="scans/fertig")


def test_the_same_folder_on_another_archive_is_fine(tmp_path):
    """Same path, different NAS - that is a move, not a loop."""
    store = _store(tmp_path)

    pickup_id = store.add(
        name="Kopierer", folder="scans", target_archive="2", target_folder="scans/fertig"
    )

    assert store.get(pickup_id).target_folder == "scans/fertig"


def test_the_name_defaults_to_the_folder(tmp_path):
    store = _store(tmp_path)

    pickup_id = store.add(folder="scans/flur")

    assert store.get(pickup_id).name == "scans/flur"


def test_paths_are_normalised(tmp_path):
    store = _store(tmp_path)

    pickup_id = store.add(folder="scans\\\\flur\\\\", target_folder="eingang/")

    pickup = store.get(pickup_id)
    assert (pickup.folder, pickup.target_folder) == ("scans/flur", "eingang")


# --- the rules a pickup plays by ----------------------------------------------


def test_files_into_itself_detects_the_loop():
    assert _pickup(folder="scans", target_folder="scans/fertig").files_into_itself() is True
    assert _pickup(folder="scans", target_folder="scans").files_into_itself() is True
    assert _pickup(folder="scans", target_folder="eingang").files_into_itself() is False
    # no fixed target: the rules decide, and they cannot point back by name
    assert _pickup(folder="scans", target_folder="").files_into_itself() is False


def test_a_similar_name_is_not_a_loop():
    assert _pickup(folder="scans", target_folder="scans-fertig").files_into_itself() is False


def test_the_rule_scope_can_never_be_a_real_account():
    """Account ids are numbers, so only "all accounts" rules may claim a scan."""
    assert _pickup(id=3).rule_scope() == "pickup:3"


# --- store --------------------------------------------------------------------


def test_add_update_delete(tmp_path):
    store = _store(tmp_path)
    pickup_id = store.add(name="Kopierer", folder="scans", target_folder="eingang")

    store.update(pickup_id, name="Kopierer Flur")
    assert store.get(pickup_id).name == "Kopierer Flur"
    assert store.get(pickup_id).target_folder == "eingang"

    store.delete(pickup_id)
    assert store.get(pickup_id) is None


def test_disabled_folders_are_not_watched(tmp_path):
    store = _store(tmp_path)
    store.add(name="Aus", folder="scans", enabled=False)

    assert store.enabled() == []


def test_deleting_a_printer_stops_the_printing(tmp_path):
    store = _store(tmp_path)
    pickup_id = store.add(name="Kopierer", folder="scans", print_attachments=True, printer="4")

    assert store.clear_printer("4") == 1

    pickup = store.get(pickup_id)
    assert (pickup.print_attachments, pickup.printer) == (False, "")
MAIL2NAS_EOF

# --- tests/test_scanning.py ---
cat > tests/test_scanning.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from mail2nas.archives import ArchiveStore, StorageSet
from mail2nas.config import parse_extension_list
from dataclasses import replace

from mail2nas.mapping import Mapping, Rule, RuleStore
from mail2nas.pickups import PickupStore
from mail2nas.printers import PrinterStore
from mail2nas.printing import PrintService
from mail2nas.scanning import PickupRunner
from tests.test_archiver import RecordingSpooler, _make_options


def _env(tmp_path, rules=None, **option_overrides):
    """A runner over <tmp_path> as the default archive, plus a second one."""
    second = tmp_path / "nas2"
    second.mkdir(exist_ok=True)

    archives = ArchiveStore(str(tmp_path / "state.db"))
    archives.add(name="Haupt", backend="local", path=str(tmp_path))
    second_id = archives.add(name="NAS 2", backend="local", path=str(second))
    storages = StorageSet(archives)

    store = RuleStore(str(tmp_path / "state.db"))
    if rules:
        store.save(rules)
    mapping = Mapping(store)

    pickups = PickupStore(str(tmp_path / "state.db"))
    options = _make_options(pickup_min_age=0, **option_overrides)
    runner = PickupRunner(options, mapping, storages, pickups)
    return runner, pickups, second, str(second_id)


def _drop(directory: Path, name: str, content: bytes = b"scan", age: int = 60) -> Path:
    """Write a file into a pickup folder, pretending it finished `age` ago."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(content)
    stamp = time.time() - age
    os.utime(path, (stamp, stamp))
    return path


# --- the basic move -----------------------------------------------------------


def test_a_ready_file_is_moved_into_the_target_folder(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "SKM_C250i.pdf")

    assert runner.run_once() == 1

    assert not source.exists()  # the folder is an outbox, not an archive
    filed = list((tmp_path / "eingang").glob("*"))
    assert len(filed) == 1
    assert filed[0].read_bytes() == b"scan"


def test_the_name_gets_the_date_and_the_folder_it_came_from(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf")

    runner.run_once()

    name = next((tmp_path / "eingang").glob("*")).name
    assert name.endswith("_Kopierer_scan.pdf")
    assert name[:4].isdigit()


def test_subfolders_are_walked(tmp_path):
    """Devices create one folder per user or scan profile."""
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans" / "anna", "a.pdf")
    _drop(tmp_path / "scans" / "bert", "b.pdf")

    assert runner.run_once() == 2
    assert len(list((tmp_path / "eingang").glob("*"))) == 2


def test_two_scans_of_the_same_name_do_not_overwrite_each_other(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, filename_prefix="none")
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf", b"erster")
    runner.run_once()
    _drop(tmp_path / "scans", "scan.pdf", b"zweiter")
    runner.run_once()

    assert sorted(p.read_bytes() for p in (tmp_path / "eingang").glob("*")) == [
        b"erster",
        b"zweiter",
    ]


# --- what is not ready --------------------------------------------------------


def test_a_file_still_being_written_is_left_alone(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    runner._options = replace(runner.options, pickup_min_age=30)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "halb.pdf", age=0)

    assert runner.run_once() == 0
    assert source.exists()


@pytest.mark.parametrize("name", ["scan.pdf.tmp", "scan.PART", "scan.crdownload", ".versteckt.pdf"])
def test_half_written_or_hidden_files_are_ignored(tmp_path, name):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", name)

    assert runner.run_once() == 0
    assert source.exists()


def test_an_empty_file_is_ignored(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "leer.pdf", b"")

    assert runner.run_once() == 0


def test_a_folder_that_does_not_exist_yet_is_created(tmp_path, caplog):
    """The device has to be able to write there - so make it, and say so once."""
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")

    with caplog.at_level("WARNING"):
        assert runner.run_once() == 0
        assert runner.run_once() == 0

    assert (tmp_path / "scans").is_dir()
    warnings = [r for r in caplog.records if r.name == "mail2nas.scanning"]
    assert len(warnings) == 1


def test_a_disabled_folder_is_not_touched(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang", enabled=False)
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


def test_dry_run_moves_nothing(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, dry_run=True)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


# --- where the document goes ---------------------------------------------------


def test_without_a_fixed_target_the_keyword_rules_decide(tmp_path):
    runner, pickups, _, _ = _env(
        tmp_path, rules=[Rule.create("Rechnung", "rechnungen")]
    )
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "Rechnung_4711.pdf")

    runner.run_once()

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_without_a_match_the_fallback_folder_is_used(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, rules=[Rule.create("Rechnung", "rechnungen")])
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "irgendwas.pdf")

    runner.run_once()

    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_rules_pinned_to_a_mailbox_do_not_claim_folder_scans(tmp_path):
    """A file from a folder arrived through no mailbox at all."""
    runner, pickups, _, _ = _env(
        tmp_path, rules=[Rule.create("Rechnung", "privat", account="2")]
    )
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "Rechnung_1.pdf")

    runner.run_once()

    assert not (tmp_path / "privat").exists()
    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_a_blocked_extension_is_quarantined(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "Rechnung.exe", b"MZ")

    runner.run_once()

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
    assert not (tmp_path / "eingang").exists()


def test_the_quarantine_list_is_read_live(tmp_path):
    """Editing it in the web UI has to take effect without a restart."""
    runner, pickups, _, _ = _env(tmp_path)
    blocked = {"value": parse_extension_list("exe")}
    base = runner.options
    runner._options = lambda: replace(base, blocked_extensions=blocked["value"])
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")

    blocked["value"] = parse_extension_list("pdf")
    _drop(tmp_path / "scans", "scan.pdf")
    runner.run_once()

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_a_target_inside_the_pickup_folder_is_skipped(tmp_path):
    """Configuration refuses it, a hand-edited database must not loop either."""
    runner, pickups, _, _ = _env(tmp_path)
    pickup_id = pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    import sqlite3

    with sqlite3.connect(str(tmp_path / "state.db")) as conn:
        conn.execute(
            "UPDATE pickup_folders SET target_folder = 'scans/fertig' WHERE id = ?", (pickup_id,)
        )
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


# --- several archives ----------------------------------------------------------


def test_a_scan_can_be_filed_onto_another_archive(tmp_path):
    runner, pickups, second, second_key = _env(tmp_path)
    pickups.add(
        name="Kopierer", folder="scans", target_archive=second_key, target_folder="eingang"
    )
    _drop(tmp_path / "scans", "scan.pdf", b"inhalt")

    assert runner.run_once() == 1

    filed = list((second / "eingang").glob("*"))
    assert len(filed) == 1 and filed[0].read_bytes() == b"inhalt"
    assert not (tmp_path / "scans" / "scan.pdf").exists()


def test_the_folder_can_live_on_the_second_archive(tmp_path):
    runner, pickups, second, second_key = _env(tmp_path)
    pickups.add(
        name="Kopierer", archive=second_key, folder="scans", target_folder="eingang"
    )
    _drop(second / "scans", "scan.pdf")

    assert runner.run_once() == 1
    assert len(list((tmp_path / "eingang").glob("*"))) == 1


# --- printing ------------------------------------------------------------------


def _printing(tmp_path, queue="drucker_a"):
    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name=queue, destination=queue))
    spooler = RecordingSpooler()
    return PrintService(store, spooler), spooler, printer_id


def test_a_pickup_can_print_what_it_files(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    printing, spooler, printer_id = _printing(tmp_path)
    runner.printing = printing
    pickups.add(
        name="Kopierer", folder="scans", target_folder="eingang",
        print_attachments=True, printer=printer_id,
    )
    _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 1

    assert spooler.printed_on == ["drucker_a"]
    assert len(list((tmp_path / "eingang").glob("*"))) == 1


def test_a_quarantined_scan_is_never_printed(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    printing, spooler, printer_id = _printing(tmp_path)
    runner.printing = printing
    pickups.add(
        name="Kopierer", folder="scans", target_folder="eingang",
        print_attachments=True, printer=printer_id,
    )
    _drop(tmp_path / "scans", "boese.exe", b"MZ")

    runner.run_once()

    assert spooler.printed_on == []
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_one_broken_folder_does_not_stop_the_others(tmp_path, monkeypatch):
    runner, pickups, _, _ = _env(tmp_path)
    broken = pickups.add(name="Kaputt", folder="fehlt", target_folder="eingang")
    original = runner._empty

    def explode(pickup):
        if pickup.id == broken:
            raise OSError("Share weg")
        return original(pickup)

    monkeypatch.setattr(runner, "_empty", explode)
    pickups.add(name="Gut", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 1
MAIL2NAS_EOF

# --- tests/test_printers.py ---
cat > tests/test_printers.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import sqlite3

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.printers import (
    PrinterError,
    PrinterStore,
    seed_from_config,
)
from mail2nas.state import SettingsStore
from tests.test_archiver import _seed_config


@pytest.fixture
def store(tmp_path):
    return PrinterStore(str(tmp_path / "state.db"))


def _add(store, **overrides) -> int:
    fields = {"name": "Buero", "destination": "Kyocera_M2540"}
    fields.update(overrides)
    return store.add(**fields)


# --- storage ------------------------------------------------------------------


def test_add_and_read_back_a_printer(store):
    printer_id = _add(store, server="cups.lan:631", options="media=A4", copies=2)

    printer = store.get(printer_id)

    assert (printer.name, printer.destination) == ("Buero", "Kyocera_M2540")
    assert (printer.server, printer.options, printer.copies) == ("cups.lan:631", "media=A4", 2)
    assert printer.enabled is True


def test_update_changes_only_what_is_passed(store):
    printer_id = _add(store, options="media=A4")

    store.update(printer_id, name="Buchhaltung")

    printer = store.get(printer_id)
    assert printer.name == "Buchhaltung"
    assert printer.options == "media=A4"


def test_paused_printers_are_kept_but_not_offered(store):
    _add(store, name="Aktiv")
    _add(store, name="Pausiert", enabled=False)

    assert [p.name for p in store.all()] == ["Aktiv", "Pausiert"]
    assert [p.name for p in store.enabled()] == ["Aktiv"]


def test_delete_removes_the_printer(store):
    printer_id = _add(store)

    store.delete(printer_id)

    assert store.get(printer_id) is None


def test_lookup_by_the_key_a_rule_stores(store):
    printer_id = _add(store)

    assert store.by_key(str(printer_id)).id == printer_id
    assert store.by_key("") is None
    assert store.by_key("keine-zahl") is None
    assert store.by_key("9999") is None


def test_options_are_split_into_separate_arguments(store):
    printer = store.get(_add(store, options="media=A4  sides=two-sided-long-edge"))

    assert printer.option_list == ["media=A4", "sides=two-sided-long-edge"]


# --- validation ---------------------------------------------------------------


def test_a_queue_name_is_required(store):
    with pytest.raises(PrinterError):
        store.add(name="Ohne Ziel", destination="")


@pytest.mark.parametrize("destination", ["zwei woerter", "-d"])
def test_an_unusable_queue_name_is_refused(store, destination):
    with pytest.raises(PrinterError):
        _add(store, destination=destination)


def test_an_option_that_looks_like_a_flag_is_refused(store):
    # "-o media=A4" would be passed on as two arguments and silently do
    # something else than what was typed.
    with pytest.raises(PrinterError):
        _add(store, options="-o media=A4")


@pytest.mark.parametrize("copies", ["null", "0", "999"])
def test_an_unusable_copy_count_is_refused(store, copies):
    with pytest.raises(PrinterError):
        _add(store, copies=copies)


def test_the_name_defaults_to_the_queue(store):
    printer = store.get(_add(store, name=""))

    assert printer.name == "Kyocera_M2540"


# --- seeding from the environment ---------------------------------------------


def _seed_env(tmp_path, **overrides):
    config = _seed_config(tmp_path, **overrides)
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    return store


def test_the_first_printer_is_created_from_the_configuration(tmp_path):
    store = _seed_env(
        tmp_path, printer_destination="Kyocera_M2540", printer_name="Buero", printer_copies=2
    )

    assert [(p.name, p.destination, p.copies) for p in store.all()] == [
        ("Buero", "Kyocera_M2540", 2)
    ]


def test_nothing_is_created_without_a_configured_queue(tmp_path):
    assert _seed_env(tmp_path).all() == []


def test_deleting_the_seeded_printer_does_not_resurrect_it(tmp_path):
    config = _seed_config(tmp_path, printer_destination="Kyocera_M2540")
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []


# --- upgrading an existing installation ---------------------------------------


def test_printing_columns_are_added_to_an_existing_account_table(tmp_path):
    """An update must not require re-entering every mailbox."""
    db_path = str(tmp_path / "state.db")
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "CREATE TABLE imap_accounts ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, host TEXT NOT NULL, "
            "port INTEGER NOT NULL DEFAULT 993, ssl INTEGER NOT NULL DEFAULT 1, "
            "user TEXT NOT NULL, password TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'INBOX', "
            "mode TEXT NOT NULL DEFAULT 'poll', processed_folder TEXT NOT NULL DEFAULT '', "
            "oversized_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute(
            "INSERT INTO imap_accounts (name, host, user, password) VALUES ('Alt', 'h', 'u', 'p')"
        )

    account = AccountStore(db_path).all()[0]

    assert account.name == "Alt"
    # Defaults keep the existing behaviour: nothing printed, everything filed.
    assert account.print_attachments is False
    assert account.printer == ""
    assert account.archive_attachments is True
MAIL2NAS_EOF

# --- tests/test_printing.py ---
cat > tests/test_printing.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import subprocess

import pytest

from mail2nas.printers import Printer, PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    build_command,
    job_title,
    parse_extensions,
)

PRINTABLE = parse_extensions("pdf,txt,png")


def _printer(**overrides) -> Printer:
    fields = dict(
        id=1, name="Buero", destination="Kyocera_M2540", server="", options="", copies=1,
        enabled=True,
    )
    fields.update(overrides)
    return Printer(**fields)


class FakeRun:
    """Stands in for subprocess.run, recording what it was asked to run."""

    def __init__(self, returncode: int = 0, stdout: str = "request id is q-1", stderr: str = ""):
        self.calls: list[list[str]] = []
        self._result = subprocess.CompletedProcess([], returncode, stdout, stderr)

    def __call__(self, command, **kwargs):
        self.calls.append(list(command))
        self.kwargs = kwargs
        return self._result


def _spooler(monkeypatch, run=None, **overrides) -> tuple[Spooler, FakeRun]:
    run = run or FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    options = dict(printable_extensions=PRINTABLE)
    options.update(overrides)
    return Spooler(**options), run


# --- the lp command -----------------------------------------------------------


def test_the_command_names_the_queue_and_the_job():
    command = build_command(_printer(), "/tmp/x.pdf", "Rechnung 4711")

    assert command[0] == "lp"
    assert command[command.index("-d") + 1] == "Kyocera_M2540"
    assert command[command.index("-t") + 1] == "Rechnung 4711"
    assert command[-2:] == ["--", "/tmp/x.pdf"]


def test_a_remote_cups_server_is_passed_with_h():
    command = build_command(_printer(server="cups.lan:631"), "/tmp/x.pdf", "t")

    assert command[command.index("-h") + 1] == "cups.lan:631"


def test_each_option_becomes_its_own_o_argument():
    command = build_command(
        _printer(options="media=A4 sides=two-sided-long-edge"), "/tmp/x.pdf", "t"
    )

    assert command.count("-o") == 2
    assert "media=A4" in command and "sides=two-sided-long-edge" in command


def test_a_single_copy_needs_no_n_argument():
    assert "-n" not in build_command(_printer(), "/tmp/x.pdf", "t")
    assert build_command(_printer(copies=3), "/tmp/x.pdf", "t").count("-n") == 1


def test_the_binary_can_be_pointed_somewhere_else():
    assert build_command(_printer(), "/tmp/x.pdf", "t", lp_binary="/usr/bin/lp")[0] == "/usr/bin/lp"


def test_the_job_title_stays_short_and_printable():
    title = job_title("Betreff\nmit Umbruch", "rechnung.pdf")

    assert "\n" not in title
    assert len(title) <= 80
    assert "rechnung.pdf" in title


# --- spooling ------------------------------------------------------------------


def test_printing_writes_the_payload_and_calls_lp(monkeypatch, tmp_path):
    seen = {}
    run = FakeRun()

    def record(command, **kwargs):
        # The temporary file must still exist - and hold the payload - at the
        # moment lp is called.
        with open(command[-1], "rb") as fh:
            seen["data"] = fh.read()
        seen["suffix"] = command[-1].rsplit(".", 1)[-1]
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)
    spooler = Spooler(printable_extensions=PRINTABLE)

    spooler.print_bytes(_printer(), b"%PDF-1.4 fake", "rechnung.pdf")

    assert seen["data"] == b"%PDF-1.4 fake"
    assert seen["suffix"] == "pdf"


def test_the_temporary_file_is_removed_afterwards(monkeypatch):
    paths = []
    run = FakeRun()

    def record(command, **kwargs):
        paths.append(command[-1])
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")

    import os

    assert paths and not os.path.exists(paths[0])


def test_a_failing_lp_reports_what_it_said(monkeypatch):
    spooler, _ = _spooler(monkeypatch, run=FakeRun(returncode=1, stderr="lp: Kein Drucker"))

    with pytest.raises(PrintError, match="Kein Drucker"):
        spooler.print_bytes(_printer(), b"x", "a.pdf")


def test_a_missing_lp_binary_says_which_package_is_missing(monkeypatch):
    def missing(command, **kwargs):
        raise FileNotFoundError(command[0])

    monkeypatch.setattr(subprocess, "run", missing)

    with pytest.raises(PrintError, match="cups-client"):
        Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")


def test_a_hanging_printer_is_given_up_on(monkeypatch):
    def hang(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 1)

    monkeypatch.setattr(subprocess, "run", hang)

    with pytest.raises(PrintError, match="abgebrochen"):
        Spooler(printable_extensions=PRINTABLE, timeout=1).print_bytes(_printer(), b"x", "a.pdf")


def test_dry_run_does_not_touch_the_printer(monkeypatch):
    spooler, run = _spooler(monkeypatch, dry_run=True)

    spooler.print_bytes(_printer(), b"x", "a.pdf")

    assert run.calls == []


def test_the_test_page_says_where_it_came_from(monkeypatch):
    printed = {}
    run = FakeRun()

    def record(command, **kwargs):
        with open(command[-1], encoding="utf-8") as fh:
            printed["text"] = fh.read()
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_test_page(_printer())

    assert "Kyocera_M2540" in printed["text"]


@pytest.mark.parametrize(
    "filename,printable",
    [("rechnung.pdf", True), ("BELEG.PDF", True), ("notiz.txt", True),
     ("rechnung.docx", False), ("ohne-endung", False)],
)
def test_only_known_formats_are_spooled(filename, printable):
    assert Spooler(printable_extensions=PRINTABLE).can_print(filename) is printable


# --- routing --------------------------------------------------------------------


@pytest.fixture
def service(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    run = FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    service = PrintService(store, Spooler(printable_extensions=PRINTABLE))
    return service, store, run


def test_the_first_configured_printer_in_the_chain_wins(service):
    printing, store, _ = service
    rule_printer = store.add(name="Regel", destination="q1")
    account_printer = store.add(name="Konto", destination="q2")

    chosen = printing.printer_for(str(rule_printer), str(account_printer))

    assert chosen.name == "Regel"


def test_an_empty_choice_falls_through_to_the_next(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("", str(account_printer)).name == "Konto"


def test_a_deleted_printer_falls_through_instead_of_failing(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("9999", str(account_printer)).name == "Konto"


def test_a_paused_printer_is_skipped(service):
    printing, store, _ = service
    paused = store.add(name="Pausiert", destination="q1", enabled=False)

    assert printing.printer_for(str(paused)) is None


def test_nothing_configured_means_no_printer(service):
    printing, _, _ = service

    assert printing.printer_for("", "") is None
    assert printing.configured() is False


def test_sending_reports_failures_instead_of_raising(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    monkeypatch.setattr(subprocess, "run", FakeRun(returncode=1, stderr="offline"))
    printing = PrintService(store, Spooler(printable_extensions=PRINTABLE))

    # A dead printer must never take the archiving down with it.
    assert printing.send(_printer(), b"x", "rechnung.pdf") is False


def test_an_unprintable_format_is_not_sent(service):
    printing, _, run = service

    assert printing.send(_printer(), b"MZ", "setup.docx") is False
    assert run.calls == []
MAIL2NAS_EOF

# --- tests/test_discovery.py ---
cat > tests/test_discovery.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import socket
import struct
import subprocess

import pytest

from mail2nas import discovery
from mail2nas.discovery import (
    DiscoveryError,
    Found,
    cups_queues,
    discover,
    parse_lpstat,
    parse_responses,
)


# --- CUPS queues -------------------------------------------------------------


def test_parse_lpstat_reads_queue_and_device():
    output = (
        "device for Buero_MFP: ipp://192.168.1.50:631/ipp/print\n"
        "device for Lager: socket://192.168.1.51:9100\n"
    )

    found = parse_lpstat(output, server="cups.lan")

    assert [(f.name, f.destination, f.server) for f in found] == [
        ("Buero_MFP", "Buero_MFP", "cups.lan"),
        ("Lager", "Lager", "cups.lan"),
    ]
    assert found[0].detail == "ipp://192.168.1.50:631/ipp/print"
    assert found[0].ready_to_use is True


def test_parse_lpstat_survives_a_localised_prefix():
    """The wording of "device for" depends on the server's locale."""
    found = parse_lpstat("Gerät für Flur: ipp://10.0.0.9/ipp/print\n")

    assert [f.destination for f in found] == ["Flur"]


@pytest.mark.parametrize("output", ["", "\n", "lpstat: keine Ziele\n"])
def test_parse_lpstat_ignores_noise(output):
    assert parse_lpstat(output) == [] or all(f.destination for f in parse_lpstat(output))


def test_cups_queues_asks_the_named_server(monkeypatch):
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        return subprocess.CompletedProcess(command, 0, "device for A: ipp://x/ipp/print\n", "")

    monkeypatch.setattr(subprocess, "run", fake_run)

    found = cups_queues("cups.lan:631", lpstat_binary="lpstat")

    assert seen["command"] == ["lpstat", "-h", "cups.lan:631", "-v"]
    assert [f.name for f in found] == ["A"]


def test_cups_queues_without_a_server_queries_the_local_one(monkeypatch):
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)

    cups_queues("")

    assert "-h" not in seen["command"]


def test_a_missing_lpstat_is_reported_usefully(monkeypatch):
    def fake_run(command, **kwargs):
        raise FileNotFoundError()

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="cups-client"):
        cups_queues("")


def test_an_unreachable_server_is_reported(monkeypatch):
    def fake_run(command, **kwargs):
        return subprocess.CompletedProcess(command, 1, "", "lpstat: Server nicht erreichbar")

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="nicht erreichbar"):
        cups_queues("cups.lan")


def test_a_hanging_server_does_not_hang_the_page(monkeypatch):
    def fake_run(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 10)

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="10s"):
        cups_queues("cups.lan", timeout=10)


# --- mDNS --------------------------------------------------------------------


def _name(value: str) -> bytes:
    return b"".join(bytes([len(p)]) + p.encode() for p in value.split(".")) + b"\x00"


def _record(name: str, rtype: int, rdata: bytes) -> bytes:
    return _name(name) + struct.pack(">HHIH", rtype, 1, 120, len(rdata)) + rdata


def _txt(**values) -> bytes:
    out = b""
    for key, value in values.items():
        chunk = f"{key}={value}".encode()
        out += bytes([len(chunk)]) + chunk
    return out


def _response(instance="Kyocera M2540._ipp._tcp.local", host="drucker.local", port=631, **txt):
    """A realistic mDNS answer: SRV + TXT + A, like a printer sends."""
    srv = struct.pack(">HHH", 0, 0, port) + _name(host)
    body = (
        _record(instance, discovery.TYPE_SRV, srv)
        + _record(instance, discovery.TYPE_TXT, _txt(**txt))
        + _record(host, discovery.TYPE_A, socket.inet_aton("192.168.1.50"))
    )
    return struct.pack(">HHHHHH", 0, 0x8400, 0, 3, 0, 0) + body


def test_parse_responses_builds_a_printer():
    found = parse_responses([_response(ty="Kyocera ECOSYS M2540", rp="ipp/print")])

    assert len(found) == 1
    printer = found[0]
    assert printer.name == "Kyocera ECOSYS M2540"
    assert printer.destination == "ipp/print"
    assert printer.server == "192.168.1.50"
    assert printer.detail == "ipp://192.168.1.50:631/ipp/print"
    assert printer.ready_to_use is False


def test_a_non_standard_port_stays_in_the_server():
    found = parse_responses([_response(port=6310, rp="ipp/print")])

    assert found[0].server == "192.168.1.50:6310"


def test_without_a_queue_in_the_txt_record_the_default_is_used():
    found = parse_responses([_response(ty="Drucker")])

    assert found[0].destination == "ipp/print"


def test_the_instance_name_is_used_when_the_txt_record_has_no_model():
    found = parse_responses([_response(instance="Flurdrucker._ipp._tcp.local")])

    assert found[0].name == "Flurdrucker"


def test_a_service_without_an_srv_record_is_skipped():
    """TXT alone says nothing about where to reach the device."""
    body = _record("X._ipp._tcp.local", discovery.TYPE_TXT, _txt(ty="X"))
    packet = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0) + body

    assert parse_responses([packet]) == []


def test_compressed_names_are_followed():
    """Responders compress repeated names - the parser has to expand them."""
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 2, 0, 0)
    # An SRV record with the full names, then a TXT record whose own name is a
    # pointer back to the instance name in the first record (offset 12, right
    # after the header) - exactly what a real responder sends.
    srv = struct.pack(">HHH", 0, 0, 631) + _name("drucker.local")
    first = _record("Drucker._ipp._tcp.local", discovery.TYPE_SRV, srv)
    second = b"\xc0\x0c" + struct.pack(">HHIH", discovery.TYPE_TXT, 1, 120, 0)

    found = parse_responses([header + first + second])

    assert [f.server for f in found] == ["drucker.local"]


@pytest.mark.parametrize(
    "packet",
    [b"", b"\x00", b"\x00" * 11, b"\xff" * 40, struct.pack(">HHHHHH", 0, 0x8400, 0, 5, 0, 0)],
)
def test_broken_packets_are_ignored_instead_of_raising(packet):
    """Anything can arrive on a multicast socket, including garbage."""
    assert parse_responses([packet]) == []


def test_a_name_pointer_loop_does_not_hang():
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0)
    loop = b"\xc0\x0c"  # points at itself
    assert parse_responses([header + loop + struct.pack(">HHIH", 33, 1, 120, 0)]) == []


def test_mdns_returns_nothing_when_multicast_is_unavailable(monkeypatch):
    """Bridged Docker networks have no multicast - that is not an error."""

    def no_socket(*args, **kwargs):
        raise OSError("Network is unreachable")

    monkeypatch.setattr(socket, "socket", no_socket)

    assert discovery.mdns_printers(timeout=0.1) == []


# --- both together -----------------------------------------------------------


def test_discover_merges_both_sources(monkeypatch):
    monkeypatch.setattr(
        discovery,
        "cups_queues",
        lambda *a, **k: [Found("A", "A", "cups.lan", "cups", "ipp://10.0.0.1/ipp/print")],
    )
    monkeypatch.setattr(
        discovery,
        "mdns_printers",
        lambda **k: [Found("B", "ipp/print", "10.0.0.2", "mdns", "ipp://10.0.0.2:631/ipp/print")],
    )

    found, problems = discover("cups.lan")

    assert [f.name for f in found] == ["A", "B"]
    assert problems == []


def test_a_device_that_already_has_a_queue_is_not_listed_twice(monkeypatch):
    uri = "ipp://10.0.0.1:631/ipp/print"
    monkeypatch.setattr(
        discovery, "cups_queues", lambda *a, **k: [Found("A", "A", "cups.lan", "cups", uri)]
    )
    monkeypatch.setattr(
        discovery, "mdns_printers", lambda **k: [Found("A", "ipp/print", "10.0.0.1", "mdns", uri)]
    )

    found, _ = discover("cups.lan")

    assert len(found) == 1


def test_a_broken_cups_server_still_leaves_the_mdns_results(monkeypatch):
    def boom(*args, **kwargs):
        raise DiscoveryError("Server nicht erreichbar")

    monkeypatch.setattr(discovery, "cups_queues", boom)
    monkeypatch.setattr(
        discovery, "mdns_printers", lambda **k: [Found("B", "ipp/print", "10.0.0.2", "mdns")]
    )

    found, problems = discover("cups.lan")

    assert [f.name for f in found] == ["B"]
    assert any("nicht erreichbar" in problem for problem in problems)


def test_finding_nothing_explains_why(monkeypatch):
    monkeypatch.setattr(discovery, "cups_queues", lambda *a, **k: [])
    monkeypatch.setattr(discovery, "mdns_printers", lambda **k: [])

    found, problems = discover("")

    assert found == []
    assert any("Multicast" in problem for problem in problems)


def test_the_lpadmin_hint_is_a_usable_command():
    entry = Found("Kyocera M2540", "ipp/print", "10.0.0.2", "mdns", "ipp://10.0.0.2:631/ipp/print")

    command = entry.lpadmin_command()

    assert command.startswith("lpadmin -p Kyocera_M2540 -v ipp://10.0.0.2:631/ipp/print")
    assert " -m everywhere" in command
MAIL2NAS_EOF

# --- tests/test_main.py ---
cat > tests/test_main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.main import reconcile
from tests.test_archiver import _make_runtime


class FakeWorker:
    """Stands in for a real IMAP worker thread."""

    def __init__(self, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def is_alive(self):
        return self.started and not self.stopped


@pytest.fixture
def runtime(tmp_path):
    return _make_runtime(tmp_path)


def _add(runtime, **fields):
    defaults = dict(name="A", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_one_worker_is_started_per_enabled_account(runtime):
    _add(runtime, name="Eins")
    _add(runtime, name="Zwei")

    workers = reconcile(runtime, {}, FakeWorker)

    assert len(workers) == 2
    assert all(worker.started for worker in workers.values())


def test_disabled_accounts_get_no_worker(runtime):
    _add(runtime, name="Aus", enabled=False)

    assert reconcile(runtime, {}, FakeWorker) == {}


def test_an_unchanged_account_keeps_its_worker(runtime):
    """A reconnect on every pass would mean reconnecting every few seconds."""
    _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = next(iter(workers.values()))

    reconcile(runtime, workers, FakeWorker)

    assert next(iter(workers.values())) is first
    assert not first.stopped


def test_changing_the_password_restarts_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, password="neu")
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers[account_id] is not first


def test_renaming_an_account_does_not_restart_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, name="Neuer Name")
    reconcile(runtime, workers, FakeWorker)

    assert not first.stopped
    assert workers[account_id] is first


def test_deleting_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.delete(account_id)
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers == {}


def test_disabling_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)

    runtime.accounts.update(account_id, enabled=False)
    reconcile(runtime, workers, FakeWorker)

    assert workers == {}


def test_a_dead_worker_is_replaced(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    workers[account_id].stopped = True

    reconcile(runtime, workers, FakeWorker)

    assert workers[account_id].is_alive()


# --- readiness: nothing is filed before there is somewhere to file to -----------


def _supervisor(runtime):
    from mail2nas.main import Supervisor

    return Supervisor(runtime, FakeWorker)


def test_without_an_archive_no_mailbox_is_watched(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert supervisor.workers == {}
    assert runtime.status.archive.ok is False
    assert "Kein Archiv" in runtime.status.archive.detail


def test_an_archive_that_fails_its_write_test_stops_the_workers(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    runtime.archives.add(name="Weg", backend="local", path=str(tmp_path / "gibt-es-nicht"))
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert supervisor.workers == {}
    assert runtime.status.archive.ok is False


def test_once_the_archive_works_the_mailboxes_are_watched(runtime):
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert len(supervisor.workers) == 1
    assert runtime.status.archive.ok is True


def test_an_archive_that_is_not_a_mount_point_is_flagged(runtime):
    """A missing bind mount looks exactly like this - so it is said loudly."""
    _supervisor(runtime).step()

    assert "kein Mountpoint" in runtime.status.archive.detail


def test_the_old_rule_file_is_taken_over_before_the_first_mail(tmp_path):
    (tmp_path / "mapping.yaml").write_text("RE: rechnungen\nLieferschein: lieferscheine\n",
                                           encoding="utf-8")
    runtime = _make_runtime(tmp_path)
    _add(runtime)

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["Lieferschein", "RE"]
    assert not (tmp_path / "mapping.yaml").exists()
    assert (tmp_path / "mapping.yaml.migriert").exists()


def test_the_rule_file_is_found_where_the_old_env_said(tmp_path):
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "regeln.yaml").write_text("RE: rechnungen\n", encoding="utf-8")
    runtime = _make_runtime(tmp_path, environ={"MAPPING_PATH": "config/regeln.yaml"})

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["RE"]


def test_a_broken_rule_file_is_left_alone_and_explained(tmp_path):
    (tmp_path / "mapping.yaml").write_text("rules: [kaputt", encoding="utf-8")
    runtime = _make_runtime(tmp_path)

    _supervisor(runtime).step()

    assert (tmp_path / "mapping.yaml").exists()
    from mail2nas.migrate import SETTING_RULES_NOTE

    assert "nicht uebernommen" in runtime.settings.get(SETTING_RULES_NOTE)


def test_rules_already_in_the_database_are_not_overwritten(tmp_path):
    from mail2nas.mapping import Rule

    (tmp_path / "mapping.yaml").write_text("ALT: alt\n", encoding="utf-8")
    runtime = _make_runtime(tmp_path)
    runtime.mapping.save([Rule.create("NEU", "neu")])

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["NEU"]


# --- IDLE reacts to a stop within seconds --------------------------------------


class _IdleClient:
    def __init__(self):
        self.idle_calls = 0

    def idle(self):
        self.idle_calls += 1

    def idle_check(self, timeout):
        import time

        time.sleep(0.01)
        return []

    def idle_done(self):
        pass


def test_a_worker_in_idle_stops_without_waiting_for_the_interval(runtime, monkeypatch):
    import threading
    import time

    from mail2nas import main as main_module

    monkeypatch.setattr(main_module, "IDLE_SLICE", 0.05)
    account_id = _add(runtime, mode="idle")
    worker = main_module._Worker(runtime, runtime.accounts.get(account_id))

    class _Archiver:
        def run_once(self, client):
            return 0

    thread = threading.Thread(
        target=worker._run_idle, args=(_Archiver(), _IdleClient(), "test"), daemon=True
    )
    thread.start()
    time.sleep(0.1)
    started = time.monotonic()
    worker.stop()
    thread.join(timeout=2)

    assert not thread.is_alive()
    assert time.monotonic() - started < 1  # not the 300 s poll interval
MAIL2NAS_EOF

# --- tests/test_migrate.py ---
cat > tests/test_migrate.py <<'MAIL2NAS_EOF'
"""Coming from an older installation, and the commands the scripts use."""
from __future__ import annotations

import io
import json

import pytest

from mail2nas import cli
from mail2nas.migrate import migration_status
from mail2nas.options import Options, OptionsError, OptionsStore, as_form, validate
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_runtime

OLD_ENV = {
    "IMAP_HOST": "imap.example.com", "IMAP_USER": "archiv@example.com",
    "IMAP_PASSWORD": "geheim", "IMAP_MODE": "idle",
    "STORAGE_BACKEND": "local", "STORAGE_ROOT": "/mnt/nas",
    "FALLBACK_FOLDER": "sonstiges", "MATCH_BODY": "true", "POLL_INTERVAL_SECONDS": "120",
    "BLOCKED_EXTENSIONS": "exe,js", "DRY_RUN": "true", "PRINTER_DESTINATION": "Buero",
    "MAPPING_PATH": "config/regeln.yaml",
}


# --- the .env of an older version is carried over, once -------------------------


def test_an_old_env_arrives_complete_in_the_database(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    account = runtime.accounts.all()[0]
    assert (account.host, account.user, account.mode) == ("imap.example.com", "archiv@example.com", "idle")
    assert [(a.backend, a.path) for a in runtime.archives.all()] == [("local", "/mnt/nas")]
    assert [p.destination for p in runtime.printers.all()] == ["Buero"]
    options = runtime.options
    assert options.fallback_folder == "sonstiges"
    assert options.match_body is True
    assert options.poll_interval == 120
    assert options.blocked_extensions == {"exe", "js"}
    assert options.dry_run is True
    assert runtime.settings.get("mapping_path") == "config/regeln.yaml"


def test_after_the_first_start_the_env_no_longer_matters(tmp_path):
    _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    runtime = _make_runtime(tmp_path, with_archive=False,
                            environ={**OLD_ENV, "FALLBACK_FOLDER": "anders"})

    assert runtime.options.fallback_folder == "sonstiges"
    assert len(runtime.accounts.all()) == 1


def test_values_edited_in_the_old_ui_beat_the_env(tmp_path):
    """The quarantine list was editable before - that is the newer statement."""
    settings = SettingsStore(str(tmp_path / "state.db"))
    settings.set("blocked_extensions", "exe,scr")

    runtime = _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    assert runtime.options.blocked_extensions == {"exe", "scr"}


def test_a_fresh_installation_starts_with_defaults_and_nothing_else(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)

    assert runtime.options == Options()
    assert runtime.accounts.all() == []
    assert runtime.archives.all() == []
    assert all(migration_status(runtime)[key] for key in
               ("options_seeded", "accounts_seeded", "archives_seeded", "printers_seeded"))


# --- the settings themselves --------------------------------------------------


def test_every_setting_round_trips_through_the_form():
    options = Options(fallback_folder="a/b", match_body=True, dry_run=True,
                      printable_extensions=frozenset({"pdf"}))

    assert validate(as_form(options)) == options


def test_a_value_broken_in_the_database_falls_back_to_its_default(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))
    settings.set("opt.poll_interval", "nie")

    assert OptionsStore(settings).load().poll_interval == Options().poll_interval


@pytest.mark.parametrize("prefix", ["", "datum"])
def test_an_unknown_filename_prefix_is_refused(prefix):
    form = as_form(Options())
    form["filename_prefix"] = prefix or "x"

    with pytest.raises(OptionsError):
        validate(form)


# --- the maintenance commands ------------------------------------------------------


@pytest.fixture
def container(tmp_path, monkeypatch):
    """Point the CLI at a database in tmp_path, like STATE_DB_PATH in the container."""
    for key in OLD_ENV:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("STATE_DB_PATH", str(tmp_path / "state.db"))
    return tmp_path


def test_status_reports_what_the_update_script_waits_for(container, capsys):
    assert cli.main(["status"]) == 0

    status = json.loads(capsys.readouterr().out)
    assert status["options_seeded"] and status["rules_migrated"] is False
    assert status["archives"] == 0


def test_the_generated_password_can_be_shown_and_reset(container, capsys):
    from mail2nas.web import SETTING_PASSWORD_HASH, ensure_password

    settings = SettingsStore(str(container / "state.db"))
    generated = ensure_password(settings, "", str(container))

    assert cli.main(["password"]) == 0
    assert capsys.readouterr().out.strip() == generated

    before = settings.get(SETTING_PASSWORD_HASH)
    assert cli.main(["reset-password"]) == 0
    new = capsys.readouterr().out.strip()
    assert new != generated
    assert settings.get(SETTING_PASSWORD_HASH) != before


def test_password_says_so_when_it_was_already_changed(container, capsys):
    assert cli.main(["password"]) == 1


def _archive_to_smb(monkeypatch, payload: dict, works: bool = True):
    from mail2nas import storage as storage_module

    class FakeSmb:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def check_writable(self):
            if not works:
                raise SystemExit("STATUS_LOGON_FAILURE")

        def close(self):
            pass

    monkeypatch.setattr(storage_module, "SmbStorage", FakeSmb)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    return cli.main(["archive-to-smb"])


SMB = {"host": "nas.lan", "share": "Belege", "user": "archiv", "password": "geheim"}


def test_a_host_mount_can_be_switched_to_direct_smb(container, monkeypatch):
    runtime = _make_runtime(container, with_archive=False)
    runtime.archives.add(name="Archiv", backend="local", path="/mnt/nas")

    assert _archive_to_smb(monkeypatch, SMB) == 0

    archive = runtime.archives.all()[0]
    assert (archive.backend, archive.host, archive.share, archive.path) == ("smb", "nas.lan", "Belege", "")


def test_a_failed_smb_test_leaves_the_mount_in_place(container, monkeypatch):
    runtime = _make_runtime(container, with_archive=False)
    runtime.archives.add(name="Archiv", backend="local", path="/mnt/nas")

    assert _archive_to_smb(monkeypatch, SMB, works=False) == 1

    assert runtime.archives.all()[0].backend == "local"


def test_nothing_to_switch_is_reported_as_such(container, monkeypatch):
    _make_runtime(container, with_archive=False)

    assert _archive_to_smb(monkeypatch, SMB) == 2
MAIL2NAS_EOF

# --- mail2nas/__init__.py ---
touch mail2nas/__init__.py

# --- tests/__init__.py ---
touch tests/__init__.py

echo "Fertig: $TARGET enthaelt jetzt das komplette mail2nas-Projekt."
echo "Naechste Schritte:"
echo "  Neuinstallation:  cd $TARGET && cp .env.example .env && docker compose up -d --build"
echo "                    Startpasswort: docker compose exec mail2nas python -m mail2nas.cli password"
echo "  Update:           MAIL2NAS_OFFLINE=1 bash $TARGET/scripts/proxmox/update.sh"
echo "  Danach alles Weitere in der Weboberflaeche (http://<ip>:8080/)."
