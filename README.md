# mail2nas

Holt Mails per IMAP ab, sortiert Anhaenge anhand eines konfigurierbaren
Mapping-Files (Stichwort im Betreff -> Zielordner) und legt sie auf einem
SMB-Share ab. Gedacht zum Betrieb als Container auf Proxmox (LXC/Docker),
kann aber genauso als einfacher systemd-Service laufen.

## Funktionsweise

1. Verbindet sich per IMAP mit dem Postfach (IDLE-Push oder Polling).
2. Liest ungelesene Mails, sucht im Betreff (optional auch im Mailtext)
   nach den Stichwoertern aus `mapping.yaml`.
3. Der erste Treffer bestimmt den Zielordner unterhalb des SMB-Shares
   (z. B. `RE`/`Rechnung` -> `rechnungen/`, `LS`/`Lieferschein` ->
   `lieferscheine/`). Ohne Treffer landen Anhaenge im `FALLBACK_FOLDER`
   (Default: `unsorted/`).
4. Anhaenge werden mit Datums-/Absender-Praefix gespeichert, Namenskollisionen
   werden automatisch durch einen Zaehler-Suffix vermieden.
5. Die Mail wird als gelesen markiert (und optional in einen
   `IMAP_PROCESSED_FOLDER` verschoben). Zusaetzlich wird die Message-ID in
   einer lokalen SQLite-Datenbank vermerkt, damit nichts doppelt verarbeitet
   wird, selbst wenn das `\Seen`-Flag von woanders zurueckgesetzt wird.
6. `mapping.yaml` liegt selbst auf dem SMB-Share und wird bei jedem Zyklus
   neu eingelesen - Anpassungen wirken ohne Neustart/Redeploy.

## Voraussetzungen

- Ein IMAP-Postfach (am besten ein dediziertes Konto/App-Passwort, keine
  Zugangsdaten eines persoenlichen Postfachs).
- Ein SMB-Share mit einem Benutzer, der Schreibrechte auf die Zielordner hat.
- Docker + Docker Compose auf dem Proxmox-Host/LXC, sowie `cifs-utils`
  installiert (fuer den CIFS-Volume-Treiber von Docker).

## Setup (Docker Compose, empfohlen)

```bash
apt-get install -y cifs-utils   # einmalig auf dem Host/LXC, falls nicht vorhanden

cp .env.example .env
$EDITOR .env                    # IMAP- und SMB-Zugangsdaten eintragen

docker compose build
docker compose up -d
docker compose logs -f
```

Danach `config/mapping.example.yaml` als `mapping.yaml` auf die Wurzel des
SMB-Shares kopieren (Pfad relativ dazu ist in `MAPPING_PATH` konfigurierbar)
und an die eigenen Stichwoerter/Ordner anpassen.

### Testlauf ohne Nebenwirkungen

`DRY_RUN=true` in der `.env` setzen und `docker compose up` laufen lassen:
es wird nur geloggt, was passieren wuerde - es werden weder Dateien
geschrieben noch IMAP-Flags/Ordner veraendert.

## Setup ohne Docker (LXC + systemd)

Falls kein Docker gewuenscht ist, laeuft das Script genauso in einer
schlanken Debian-LXC mit Python-venv:

```bash
apt-get install -y python3-venv cifs-utils
python3 -m venv /opt/mail2nas/venv
/opt/mail2nas/venv/bin/pip install -r requirements.txt

# SMB-Share direkt in der LXC mounten, z. B. via /etc/fstab:
# //nas.local/Belege /mnt/nas cifs credentials=/etc/mail2nas-smb-credentials,uid=mail2nas,gid=mail2nas,vers=3.0 0 0
mount /mnt/nas
```

Anschliessend als systemd-Service einrichten (`/etc/systemd/system/mail2nas.service`):

```ini
[Unit]
Description=mail2nas IMAP-to-SMB archiver
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
EnvironmentFile=/opt/mail2nas/.env
ExecStart=/opt/mail2nas/venv/bin/python -m mail2nas.main
WorkingDirectory=/opt/mail2nas
Restart=on-failure
RestartSec=10
User=mail2nas

[Install]
WantedBy=multi-user.target
```

`.env` in diesem Fall lokal unter `/opt/mail2nas/.env` ablegen (mit
`STORAGE_ROOT=/mnt/nas`) und `systemctl enable --now mail2nas` ausfuehren.

## Konfiguration (Environment-Variablen)

| Variable | Beschreibung | Default |
|---|---|---|
| `IMAP_HOST` / `IMAP_PORT` / `IMAP_SSL` | IMAP-Server-Zugangsdaten | - / `993` / `true` |
| `IMAP_USER` / `IMAP_PASSWORD` | IMAP-Login | - |
| `IMAP_FOLDER` | Zu ueberwachender Ordner | `INBOX` |
| `IMAP_PROCESSED_FOLDER` | Optional: Zielordner fuer verarbeitete Mails | leer (nur `\Seen`) |
| `IMAP_MODE` | `idle` (Push) oder `poll` | `poll` |
| `POLL_INTERVAL_SECONDS` | Intervall im Poll-Modus bzw. IDLE-Refresh | `300` |
| `STORAGE_ROOT` | Wurzelverzeichnis des gemounteten SMB-Shares im Container | `/mnt/nas` |
| `MAPPING_PATH` | Pfad zur `mapping.yaml`, relativ zu `STORAGE_ROOT` | `mapping.yaml` |
| `FALLBACK_FOLDER` | Zielordner ohne Mapping-Treffer | `unsorted` |
| `MATCH_BODY` | Zusaetzlich den Mailtext durchsuchen | `false` |
| `FILENAME_PREFIX` | `none` \| `date` \| `sender` \| `date_sender` | `date_sender` |
| `STATE_DB_PATH` | Pfad zur SQLite-Datei fuer bereits verarbeitete Mails | `/data/state.db` |
| `DRY_RUN` | Nichts schreiben, nur loggen | `false` |
| `LOG_LEVEL` | Log-Level | `INFO` |

SMB-Zugangsdaten (`SMB_HOST`, `SMB_SHARE`, `SMB_USER`, `SMB_PASSWORD`,
`SMB_DOMAIN`) werden nur vom CIFS-Volume-Treiber in `docker-compose.yml`
verwendet, nicht vom Python-Code selbst.

## Mapping-Datei

Siehe `config/mapping.example.yaml`. Format:

```yaml
RE: rechnungen
Rechnung: rechnungen
LS: lieferscheine
Lieferschein: lieferscheine
```

Laengere Stichwoerter werden vor kuerzeren geprueft (verhindert, dass z. B.
"Rechnungskorrektur" bereits durch "RE" gematcht wird).

## Tests

```bash
pip install -r requirements-dev.txt
pytest
```

## Sicherheitshinweise

- `.env` niemals committen (steht in `.gitignore`).
- Dediziertes IMAP-Konto mit App-Passwort statt Zugangsdaten eines
  Hauptpostfachs verwenden.
- Dedizierten SMB-Benutzer mit Schreibrechten nur auf die relevanten
  Zielordner einrichten, statt vollem Share-Zugriff.
