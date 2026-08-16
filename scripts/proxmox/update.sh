#!/usr/bin/env bash
#
# mail2nas - Update auf den aktuellen Stand, ohne Neukonfiguration.
#
# INNERHALB der LXC/VM ausfuehren, in der mail2nas laeuft:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"
#
# Oder vom Proxmox-Host aus:
#
#   pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"
#
# Es werden KEINE Zugangsdaten abgefragt oder benoetigt. Unangetastet bleiben:
#   - /opt/mail2nas/.env          (IMAP-/SMB-Zugangsdaten, alle Einstellungen)
#   - mapping.yaml                (liegt auf dem SMB-Share, nicht im Repo)
#   - das Docker-Volume "state"   (bereits verarbeitete Message-IDs, damit
#                                  nach dem Update nichts doppelt archiviert wird)
#
# Optional per Umgebungsvariable:
#   MAIL2NAS_TARGET_DIR   (Default: /opt/mail2nas)
#   MAIL2NAS_REPO_BRANCH  (Default: der aktuell ausgecheckte Branch, sonst main)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausfuehren." >&2
  exit 1
fi

TARGET_DIR="${MAIL2NAS_TARGET_DIR:-/opt/mail2nas}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "Verzeichnis $TARGET_DIR existiert nicht - ist mail2nas hier installiert?" >&2
  echo "Fuer eine Erstinstallation siehe scripts/proxmox/install.sh." >&2
  exit 1
fi

if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "$TARGET_DIR ist kein git-Checkout." >&2
  echo "Diese Installation stammt vermutlich aus scripts/bootstrap.sh (Offline-Variante)." >&2
  echo "Update dort: bootstrap.sh erneut ausfuehren, danach:" >&2
  echo "  cd $TARGET_DIR && docker compose up -d --build" >&2
  exit 1
fi

if [ ! -f "$TARGET_DIR/.env" ]; then
  echo "Keine $TARGET_DIR/.env gefunden - es gibt hier nichts zu erhalten." >&2
  echo "Bitte zuerst eine Erstinstallation durchfuehren (scripts/proxmox/install.sh)." >&2
  exit 1
fi

cd "$TARGET_DIR"

BRANCH="${MAIL2NAS_REPO_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
[ "$BRANCH" = "HEAD" ] && BRANCH=main

BEFORE="$(git rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

echo "==> Sicherung der Konfiguration anlegen ..."
cp -a .env ".env.bak.$(date +%Y%m%d-%H%M%S)"

echo "==> Code aktualisieren (Branch: $BRANCH, aktuell: $BEFORE) ..."
git fetch --depth 1 origin "$BRANCH"
git reset --hard FETCH_HEAD

AFTER="$(git rev-parse --short HEAD)"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "==> Bereits auf dem aktuellen Stand ($AFTER) - baue trotzdem neu, damit"
  echo "    Basis-Image und Abhaengigkeiten aktuelle Sicherheitsupdates bekommen."
else
  echo "==> Aktualisiert: $BEFORE -> $AFTER"
fi

echo "==> Neu bauen und starten (--pull, damit auch das Basis-Image aktualisiert wird) ..."
docker compose build --pull
docker compose up -d

echo "==> Aufraeumen alter, nicht mehr referenzierter Images ..."
docker image prune -f >/dev/null 2>&1 || true

echo
echo "Update abgeschlossen ($BEFORE -> $AFTER). Konfiguration unveraendert."
echo "Status:  cd $TARGET_DIR && docker compose ps"
echo "Logs:    cd $TARGET_DIR && docker compose logs -f"
