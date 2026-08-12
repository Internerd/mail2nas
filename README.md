# mail2nas

Holt Mails per IMAP ab, sortiert Anhaenge anhand eines konfigurierbaren
Mapping-Files (Stichwort im Betreff -> Zielordner) und legt sie auf einem
SMB-Share ab. Gedacht zum Betrieb als Container auf Proxmox (LXC/Docker),
kann aber genauso als einfacher systemd-Service laufen.

## Inhaltsverzeichnis

- [Funktionsweise](#funktionsweise)
- [Voraussetzungen](#voraussetzungen)
- [Installation auf Proxmox ohne Git (manuelles Kopieren)](#installation-auf-proxmox-ohne-git-manuelles-kopieren)
- [Weiter mit Docker Compose](#weiter-mit-docker-compose)
- [Alternative ohne Docker (LXC + systemd)](#alternative-ohne-docker-lxc--systemd)
- [Konfiguration (Environment-Variablen)](#konfiguration-environment-variablen)
- [Mapping-Datei](#mapping-datei)
- [Betrieb & Troubleshooting](#betrieb--troubleshooting)
- [Tests](#tests)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Updates einspielen](#updates-einspielen)

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
- Ein Proxmox-Host mit einer LXC (Debian/Ubuntu-Template) oder VM, auf der
  entweder Docker+Compose oder Python 3.11+ verfuegbar ist.
- `cifs-utils`, um das SMB-Share einzubinden.
- Zugriff auf `apt`/`pip` fuer Paketinstallationen (Internet oder ein
  interner Mirror) - **git/GitHub wird nicht benoetigt**, siehe naechster
  Abschnitt.

## Installation auf Proxmox ohne Git (manuelles Kopieren)

Wenn der Proxmox-Host bzw. die LXC keinen Zugriff auf git/GitHub hat (z. B.
wegen Firewall/Proxy), gibt es zwei Wege, den Code trotzdem draufzubekommen:

### Variante A: Ein Bootstrap-Skript per Copy & Paste (am einfachsten)

Im Repo liegt `scripts/bootstrap.sh` - ein einzelnes, in sich geschlossenes
Shell-Skript, das die komplette Projektstruktur (Python-Code, Dockerfile,
docker-compose.yml, Beispiel-Mapping, Tests) neu erzeugt. Es braucht dafuer
nichts weiter als `bash` - kein git, keine Internetverbindung fuer den Code
selbst.

1. Auf einem Rechner mit Zugriff auf dieses Repository (z. B. der eigene
   Laptop, oder wo auch immer der Code gerade vorliegt) den Inhalt von
   `scripts/bootstrap.sh` oeffnen und den kompletten Text kopieren.
2. Per SSH auf den Proxmox-Host bzw. in die Ziel-LXC verbinden:
   ```bash
   ssh root@proxmox-host
   # bzw. innerhalb der LXC:
   pct enter <CTID>
   ```
3. Eine neue Datei anlegen und den kopierten Inhalt einfuegen:
   ```bash
   nano bootstrap.sh
   # Inhalt einfuegen (Rechtsklick/Strg+Umschalt+V im Terminal), speichern mit Strg+O, Strg+X
   ```
4. Ausfuehren - das Zielverzeichnis ist optional, Default ist `/opt/mail2nas`:
   ```bash
   bash bootstrap.sh /opt/mail2nas
   ```
   Das Skript legt darunter `mail2nas/` (Python-Paket), `config/`, `tests/`,
   `requirements*.txt`, `Dockerfile`, `docker-compose.yml`, `.env.example`
   und `.dockerignore` an.
5. Weiter geht's ab [Weiter mit Docker Compose](#weiter-mit-docker-compose)
   bzw. [Alternative ohne Docker](#alternative-ohne-docker-lxc--systemd).

Das Skript ist idempotent: erneutes Ausfuehren ueberschreibt die Dateien
einfach neu (z. B. um eine neue Version einzuspielen, siehe
[Updates einspielen](#updates-einspielen)). Eigene `.env` und `mapping.yaml`
auf dem SMB-Share bleiben davon unberuehrt, da sie nicht Teil des Skripts
sind.

### Variante B: Fertigen Ordner per scp/sftp uebertragen

Falls irgendein Rechner (Laptop, Jump-Host, ...) sowohl Zugriff auf den
Code als auch Netzwerkzugriff auf den Proxmox-Host hat, aber der
Proxmox-Host selbst offline/isoliert ist:

1. Auf dem Rechner mit dem Code ein Archiv bauen:
   ```bash
   tar czf mail2nas.tar.gz \
     mail2nas requirements.txt requirements-dev.txt \
     Dockerfile docker-compose.yml .env.example .dockerignore \
     config tests
   ```
2. Archiv auf den Proxmox-Host bzw. in die LXC kopieren:
   ```bash
   scp mail2nas.tar.gz root@proxmox-host:/opt/
   # bei einer LXC ohne direkten SSH-Zugriff z. B. ueber den Proxmox-Host:
   pct push <CTID> mail2nas.tar.gz /opt/mail2nas.tar.gz
   ```
3. Auf dem Zielsystem entpacken:
   ```bash
   mkdir -p /opt/mail2nas
   tar xzf /opt/mail2nas.tar.gz -C /opt/mail2nas
   cd /opt/mail2nas
   ```

Beide Varianten fuehren zum selben Ergebnis: ein vollstaendiger
`/opt/mail2nas`-Ordner, bereit fuer die Konfiguration.

## Weiter mit Docker Compose

Empfohlener Weg, sobald der Ordner (per Variante A oder B) auf dem Zielsystem
liegt:

```bash
cd /opt/mail2nas

# einmalig, falls noch nicht vorhanden - noetig fuer den CIFS-Volume-Treiber
apt-get update && apt-get install -y docker.io docker-compose-plugin cifs-utils

cp .env.example .env
$EDITOR .env                    # IMAP- und SMB-Zugangsdaten eintragen

docker compose build
docker compose up -d
docker compose logs -f
```

Danach `config/mapping.example.yaml` als `mapping.yaml` auf die Wurzel des
SMB-Shares kopieren (Pfad relativ dazu ist in `MAPPING_PATH` konfigurierbar)
und an die eigenen Stichwoerter/Ordner anpassen - z. B. direkt vom
Proxmox-Host aus, sobald das Share gemountet ist:

```bash
# Beispiel: Share ist unter /mnt/nas-tmp erreichbar
cp config/mapping.example.yaml /mnt/nas-tmp/mapping.yaml
$EDITOR /mnt/nas-tmp/mapping.yaml
```

Falls kein separater Mount-Zugriff aufs Share besteht, reicht es auch, die
Datei einmalig ueber einen beliebigen SMB-Client (Windows-Explorer,
`smbclient`, ...) auf das Share zu legen.

### Testlauf ohne Nebenwirkungen

`DRY_RUN=true` in der `.env` setzen und `docker compose up` laufen lassen:
es wird nur geloggt, was passieren wuerde - es werden weder Dateien
geschrieben noch IMAP-Flags/Ordner veraendert.

```bash
docker compose logs -f | grep -i dry-run
```

## Alternative ohne Docker (LXC + systemd)

Falls kein Docker gewuenscht ist, laeuft das Script genauso in einer
schlanken Debian-LXC mit Python-venv - auch das komplett ohne git, sobald
der Ordner per Bootstrap-Skript oder scp vorliegt (siehe oben).

```bash
cd /opt/mail2nas

apt-get update && apt-get install -y python3-venv python3-pip cifs-utils
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# SMB-Zugangsdaten in einer separaten, nur fuer root lesbaren Datei ablegen:
cat > /etc/mail2nas-smb-credentials <<'EOF'
username=mail2nas
password=changeme
domain=WORKGROUP
EOF
chmod 600 /etc/mail2nas-smb-credentials

mkdir -p /mnt/nas

# SMB-Share dauerhaft einbinden, z. B. via /etc/fstab:
echo '//nas.local/Belege /mnt/nas cifs credentials=/etc/mail2nas-smb-credentials,uid=mail2nas,gid=mail2nas,vers=3.0,_netdev 0 0' >> /etc/fstab

# Systembenutzer fuer den Dienst anlegen
useradd --system --home /opt/mail2nas --shell /usr/sbin/nologin mail2nas || true

mount /mnt/nas
```

Danach `.env` lokal anlegen (mit `STORAGE_ROOT=/mnt/nas`):

```bash
cp .env.example .env
$EDITOR .env
chown -R mail2nas:mail2nas /opt/mail2nas
```

Anschliessend als systemd-Service einrichten
(`/etc/systemd/system/mail2nas.service`):

```ini
[Unit]
Description=mail2nas IMAP-to-SMB archiver
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
EnvironmentFile=/opt/mail2nas/.env
Environment=STORAGE_ROOT=/mnt/nas
Environment=STATE_DB_PATH=/opt/mail2nas/state.db
ExecStart=/opt/mail2nas/venv/bin/python -m mail2nas.main
WorkingDirectory=/opt/mail2nas
Restart=on-failure
RestartSec=10
User=mail2nas

[Install]
WantedBy=multi-user.target
```

Diese Datei kann genauso wie das Bootstrap-Skript per Copy&Paste (`nano
/etc/systemd/system/mail2nas.service`) angelegt werden. Danach aktivieren:

```bash
systemctl daemon-reload
systemctl enable --now mail2nas
systemctl status mail2nas
journalctl -u mail2nas -f
```

`mapping.yaml` wie im Docker-Abschnitt beschrieben auf `/mnt/nas` (bzw. den
konfigurierten `MAPPING_PATH`) kopieren.

## Konfiguration (Environment-Variablen)

| Variable | Beschreibung | Default |
|---|---|---|
| `IMAP_HOST` / `IMAP_PORT` / `IMAP_SSL` | IMAP-Server-Zugangsdaten | - / `993` / `true` |
| `IMAP_USER` / `IMAP_PASSWORD` | IMAP-Login | - |
| `IMAP_FOLDER` | Zu ueberwachender Ordner | `INBOX` |
| `IMAP_PROCESSED_FOLDER` | Optional: Zielordner fuer verarbeitete Mails | leer (nur `\Seen`) |
| `IMAP_MODE` | `idle` (Push) oder `poll` | `poll` |
| `POLL_INTERVAL_SECONDS` | Intervall im Poll-Modus bzw. IDLE-Refresh | `300` |
| `STORAGE_ROOT` | Wurzelverzeichnis des gemounteten SMB-Shares | `/mnt/nas` |
| `MAPPING_PATH` | Pfad zur `mapping.yaml`, relativ zu `STORAGE_ROOT` | `mapping.yaml` |
| `FALLBACK_FOLDER` | Zielordner ohne Mapping-Treffer | `unsorted` |
| `MATCH_BODY` | Zusaetzlich den Mailtext durchsuchen | `false` |
| `FILENAME_PREFIX` | `none` \| `date` \| `sender` \| `date_sender` | `date_sender` |
| `STATE_DB_PATH` | Pfad zur SQLite-Datei fuer bereits verarbeitete Mails | `/data/state.db` |
| `DRY_RUN` | Nichts schreiben, nur loggen | `false` |
| `LOG_LEVEL` | Log-Level | `INFO` |

SMB-Zugangsdaten (`SMB_HOST`, `SMB_SHARE`, `SMB_USER`, `SMB_PASSWORD`,
`SMB_DOMAIN`) werden nur vom CIFS-Volume-Treiber in `docker-compose.yml`
verwendet, nicht vom Python-Code selbst. Im systemd/venv-Betrieb entfallen
sie, da das Share dort direkt per `/etc/fstab` gemountet wird.

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

## Betrieb & Troubleshooting

- **Logs pruefen**: `docker compose logs -f` bzw. `journalctl -u mail2nas -f`.
  Jede verarbeitete Mail wird mit UID, Betreff, getroffenem Stichwort,
  Zielordner und gespeicherten Dateien geloggt.
- **Nichts passiert**: pruefen, ob das SMB-Share tatsaechlich gemountet ist
  (`mount | grep cifs` bzw. `docker volume inspect mail2nas_nas`), und ob
  `mapping.yaml` unter dem konfigurierten `MAPPING_PATH` liegt.
- **Mail landet immer im Fallback-Ordner**: Stichwort in `mapping.yaml`
  pruefen (Betreff-Text muss das Stichwort als Teilstring enthalten, Gross-/
  Kleinschreibung ist egal); bei Bedarf `MATCH_BODY=true` setzen, um auch
  den Mailtext zu durchsuchen.
- **Mail wird doppelt verarbeitet**: sollte durch die SQLite-Statusdatei
  (`STATE_DB_PATH`) verhindert werden. Bei einem kompletten Neuaufsetzen des
  Containers/Diensts bleibt diese Datei erhalten, solange das zugehoerige
  Volume (`state`) bzw. der Pfad im systemd-Betrieb nicht geloescht wird.
- **CIFS-Mount schlaegt fehl**: SMB-Protokollversion pruefen (`vers=3.0` ist
  meist am kompatibelsten), sowie ob der SMB-Benutzer tatsaechlich
  Schreibrechte auf dem Share hat.

## Tests

```bash
python3 -m venv venv
venv/bin/pip install -r requirements-dev.txt
venv/bin/pytest
```

## Sicherheitshinweise

- `.env` niemals committen (steht in `.gitignore`) und mit restriktiven
  Dateirechten ablegen (`chmod 600 .env`).
- Dediziertes IMAP-Konto mit App-Passwort statt Zugangsdaten eines
  Hauptpostfachs verwenden.
- Dedizierten SMB-Benutzer mit Schreibrechten nur auf die relevanten
  Zielordner einrichten, statt vollem Share-Zugriff.
- Im systemd-Betrieb liegen die SMB-Zugangsdaten in
  `/etc/mail2nas-smb-credentials` - Datei mit `chmod 600` nur fuer `root`
  lesbar halten.

## Updates einspielen

Ohne git gibt es zwei Wege, eine neue Version des Codes einzuspielen:

- **Bootstrap-Skript erneut ausfuehren** (Variante A oben) - ueberschreibt
  alle Code-Dateien, laesst `.env` und die auf dem SMB-Share liegende
  `mapping.yaml` unangetastet. Danach `docker compose build && docker
  compose up -d` (bzw. `systemctl restart mail2nas` im venv-Betrieb).
- **Neues Archiv per scp uebertragen** (Variante B oben) und das alte
  Verzeichnis ersetzen - `.env` vorher sichern, da sie nicht Teil des
  Archivs ist.
