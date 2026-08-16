# mail2nas

Holt Mails per IMAP ab, sortiert Anhaenge anhand eines konfigurierbaren
Mapping-Files (Stichwort im Betreff -> Zielordner) und legt sie auf einem
SMB-Share ab. Gedacht zum Betrieb als Container auf Proxmox (LXC/Docker),
kann aber genauso als einfacher systemd-Service laufen.

## Inhaltsverzeichnis

- [Funktionsweise](#funktionsweise)
- [Voraussetzungen](#voraussetzungen)
- [Installation, Variante 1: Proxmox-Helper-Skript (automatisch)](#installation-variante-1-proxmox-helper-skript-automatisch)
- [Installation, Variante 2: Proxmox ohne Git (manuelles Kopieren)](#installation-variante-2-proxmox-ohne-git-manuelles-kopieren)
- [Weiter mit Docker Compose](#weiter-mit-docker-compose)
- [Alternative ohne Docker (LXC + systemd)](#alternative-ohne-docker-lxc--systemd)
- [Warum der SMB-Mount auf dem Host passiert](#warum-der-smb-mount-auf-dem-host-passiert)
- [Konfiguration (Environment-Variablen)](#konfiguration-environment-variablen)
- [Mapping-Datei und Mehrfach-Anhaenge](#mapping-datei-und-mehrfach-anhaenge)
- [Sicherheit: Angriffsflaeche ueber Mail/Anhaenge](#sicherheit-angriffsflaeche-ueber-mailanhaenge)
- [Betrieb & Troubleshooting](#betrieb--troubleshooting)
- [Tests](#tests)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Datenschutz (DSGVO)](#datenschutz-dsgvo)
- [Rechnungsarchivierung / GoBD-Hinweis](#rechnungsarchivierung--gobd-hinweis)
- [Haftungsausschluss](#haftungsausschluss)
- [Lizenz](#lizenz)
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

## Installation, Variante 1: Proxmox-Helper-Skript (automatisch)

Der schnellste Weg, sofern der Proxmox-Host Internetzugriff auf GitHub hat:
ein einzelner Befehl in der Proxmox-VE-Shell (Rechenzentrum -> Node -> Shell,
**nicht** in einer Container-Konsole), angelehnt an den Stil der bekannten
[Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/)
(eigenstaendige Neuimplementierung fuer dieses Projekt, keine Codeuebernahme):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/mail2nas.sh)"
```

Das Skript:

1. Fragt (per whiptail-Dialogen) nach Container-Ressourcen (CTID, Hostname,
   CPU/RAM/Disk, Netzwerk-Bridge) - mit sinnvollen Defaults, die sich per
   "Standard-Einstellungen? Nein" auch im Detail anpassen lassen.
2. Fragt anschliessend nach den IMAP- und SMB-Zugangsdaten sowie dem
   Mapping-Pfad und Fallback-Ordner.
3. Legt eine neue, unprivilegierte Debian-12-LXC an (`pct create`).
4. Installiert darin Docker, git und cifs-utils, klont dieses Repository,
   schreibt die `.env` aus deinen Eingaben und startet den Dienst
   (`docker compose up -d`).
5. Zeigt am Ende die Container-IP sowie die Befehle zum Log-Ansehen und fuer
   einen Testlauf.

Alle eingegebenen Passwoerter landen ausschliesslich in der `.env` innerhalb
der neuen LXC (Rechte `600`) - nicht im Bash-Verlauf des Proxmox-Hosts: die
temporaere Uebergabedatei auf dem Host wird per `shred` entfernt, sobald sie
in den Container kopiert wurde.

Nicht abgefragt werden die Sicherheits-/Feinjustierungs-Variablen (Groessen-
limits, Blockliste, `MATCH_BODY`, ...) - dafuer gelten die dokumentierten
Defaults (siehe [Konfiguration](#konfiguration-environment-variablen)); nach
der Installation einfach in `/opt/mail2nas/.env` in der LXC anpassen und
`docker compose up -d` erneut ausfuehren.

Danach fehlt nur noch `config/mapping.example.yaml` (liegt im Container unter
`/opt/mail2nas/config/`) als `mapping.yaml` auf die Wurzel des SMB-Shares zu
kopieren, siehe [Mapping-Datei](#mapping-datei-und-mehrfach-anhaenge).

**Voraussetzung**: Der Proxmox-Host selbst braucht dafuer Internetzugriff auf
GitHub (fuer den `curl`-Aufruf und den `git clone` in der LXC) sowie auf die
Debian-Paketquellen und `get.docker.com`. Wenn das nicht gegeben ist, siehe
Variante 2.

Falls du schon eine Container/VM hast und nur den App-Teil (Docker, Code,
`.env`) darin einrichten willst - ohne dass das Skript selbst eine LXC
anlegt - kannst du auch direkt `scripts/proxmox/install.sh` **innerhalb**
dieser Umgebung ausfuehren:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/install.sh)"
```

Das fragt nicht interaktiv nach - es erwartet die Konfiguration als bereits
gesetzte Umgebungsvariablen (z. B. `IMAP_HOST=... IMAP_USER=... bash -c "..."`,
siehe Variablenliste im Skript-Kopf).

## Installation, Variante 2: Proxmox ohne Git (manuelles Kopieren)

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
apt-get update && apt-get install -y docker.io docker-compose-plugin cifs-utils

# Das SMB-Share zuerst per Betriebssystem einbinden - NICHT per Docker,
# siehe "Warum der SMB-Mount auf dem Host passiert".
cat > /etc/mail2nas-smb-credentials <<'EOF'
username=mail2nas
password=changeme
EOF
chmod 600 /etc/mail2nas-smb-credentials
mkdir -p /mnt/nas
echo '//nas.local/Belege /mnt/nas cifs credentials=/etc/mail2nas-smb-credentials,uid=1000,gid=1000,file_mode=0660,dir_mode=0770,vers=3.0,_netdev,nofail 0 0' >> /etc/fstab
mount /mnt/nas
mountpoint /mnt/nas          # muss "is a mountpoint" melden

cd /opt/mail2nas
cp .env.example .env
$EDITOR .env                 # IMAP-Zugangsdaten eintragen, NAS_PATH pruefen

docker compose up -d --build
docker compose logs -f
```

Danach `config/mapping.example.yaml` als `mapping.yaml` auf die Wurzel des
Shares kopieren (Pfad relativ dazu ist in `MAPPING_PATH` konfigurierbar) und
an die eigenen Stichwoerter/Ordner anpassen:

```bash
cp config/mapping.example.yaml /mnt/nas/mapping.yaml
$EDITOR /mnt/nas/mapping.yaml
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

## Warum der SMB-Mount auf dem Host passiert

Das SMB-Share wird **nicht von Docker** gemountet, sondern vom Betriebssystem
eine Ebene hoeher. Docker bekommt nur einen gewoehnlichen Bind-Mount eines
bereits eingebundenen Verzeichnisses.

Der naheliegende Weg - Dockers `local`-Volume-Treiber mit `type: cifs` -
funktioniert in der hier empfohlenen Umgebung naemlich nicht:

- Dieser Treiber setzt den `mount()`-Syscall **selbst** ab (er benutzt nicht
  das Hilfsprogramm `mount.cifs`). Fuer Dateisysteme wie CIFS verweigert der
  Kernel diesen Syscall aus dem User-Namespace einer **unprivilegierten LXC**.
  Ergebnis ist die wenig aussagekraeftige Meldung:
  ```
  failed to mount local volume: ... vers=3.0,uid=1000,... : invalid argument
  ```
- Zusaetzlich landet das SMB-Passwort dabei dauerhaft in den Volume-Metadaten
  des Docker-Daemons und ist per `docker volume inspect` auslesbar.

Beides entfaellt mit dem Mount auf Host-Ebene. Die Aufteilung sieht so aus:

```
Proxmox-Host   /etc/fstab:  //nas/share  ->  /mnt/mail2nas-<CTID>   (cifs)
                                 |
                   pct -mp0 Bind-Mount   ->  /mnt/nas   (in der LXC)
                                 |
              docker compose Bind-Mount  ->  /mnt/nas   (im Container)
```

Konkrete Vorteile:

- Funktioniert mit einer **unprivilegierten** LXC - die brauchst du nicht
  aufzuweichen, nur damit ein Mount klappt.
- Die SMB-Zugangsdaten liegen ausschliesslich auf dem Host in
  `/etc/mail2nas-smb-credentials-<CTID>` (`chmod 600`) und nie im Container
  oder in der `.env`.
- Der Host kuemmert sich um Reconnects nach einem Netzwerkausfall, statt dass
  jeder Container das einzeln tut.

`scripts/proxmox/mail2nas.sh` richtet das alles automatisch ein (inklusive
`fstab`-Eintrag mit Sicherung der bisherigen Datei). Bei einer VM oder auf
Bare Metal ohne LXC gilt dasselbe Prinzip: Share per `/etc/fstab` nach
`/mnt/nas` mounten, `NAS_PATH` zeigt dann dorthin.

### uid-Mapping bei unprivilegierten Containern

Der Docker-Container laeuft als uid 1000. Proxmox bildet den User-Namespace
einer unprivilegierten LXC ab 100000 ab, aus uid 1000 im Container wird auf
dem Host also **101000**. Genau diesen Wert traegt das Installationsskript im
`fstab`-Eintrag als `uid=`/`gid=` ein - sonst gehoerten die gemounteten
Dateien im Container niemandem und waeren nicht beschreibbar. Bei einem
privilegierten Container bleibt es bei `uid=1000`.

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
| `IMAP_OVERSIZED_FOLDER` | Optional: Zielordner fuer zu grosse Mails (siehe `MAX_MESSAGE_SIZE_MB`) | leer (nur `\Seen`) |
| `STATE_DB_PATH` | Pfad zur SQLite-Datei fuer bereits verarbeitete Mails | `/data/state.db` |
| `MAX_ATTACHMENT_SIZE_MB` | Einzelne Anhaenge ueber diesem Limit werden uebersprungen | `25` |
| `MAX_MESSAGE_SIZE_MB` | Mails ueber diesem Limit werden gar nicht erst geladen | `50` |
| `MAX_ATTACHMENTS_PER_MESSAGE` | Anhaenge ueber diesem Limit werden nicht mehr verarbeitet | `20` |
| `BLOCKED_EXTENSIONS` | Komma-Liste Dateiendungen, die immer in `QUARANTINE_FOLDER` landen | siehe `.env.example` |
| `QUARANTINE_FOLDER` | Zielordner fuer Anhaenge mit gesperrter Dateiendung | `quarantaene` |
| `NAS_PATH` | Pfad des bereits gemounteten Shares auf dem Docker-Host, wird nach `/mnt/nas` im Container gebunden | `/mnt/nas` |
| `DRY_RUN` | Nichts schreiben, nur loggen | `false` |
| `LOG_LEVEL` | Log-Level | `INFO` |

**Keine SMB-Zugangsdaten in der `.env`.** Das Share wird vom Betriebssystem
gemountet, nicht von Docker - die Zugangsdaten liegen daher in einer
Credentials-Datei mit `chmod 600` (beim Helper-Skript
`/etc/mail2nas-smb-credentials-<CTID>` auf dem Proxmox-Host). Siehe
[Warum der SMB-Mount auf dem Host passiert](#warum-der-smb-mount-auf-dem-host-passiert).
`NAS_PATH` sagt Docker nur, welches bereits gemountete Verzeichnis es
durchreichen soll.

## Mapping-Datei und Mehrfach-Anhaenge

Siehe `config/mapping.example.yaml`. Format:

```yaml
RE: rechnungen
Rechnung: rechnungen
LS: lieferscheine
Lieferschein: lieferscheine
```

Laengere Stichwoerter werden vor kuerzeren geprueft (verhindert, dass z. B.
"Rechnungskorrektur" bereits durch "RE" gematcht wird).

**Mehrere Anhaenge pro Mail werden einzeln behandelt.** Jeder Anhang wird
zuerst anhand seines EIGENEN Dateinamens gegen das Mapping geprueft; erst
wenn der Dateiname selbst keinen Treffer liefert, greift der Treffer aus
Betreff (bzw. Mailtext, siehe `MATCH_BODY`) als Fallback fuer diesen Anhang.
Dadurch landet z. B. eine Mail mit `Rechnung_4711.pdf` UND
`Lieferschein_4711.pdf` im Anhang korrekt aufgeteilt in `rechnungen/` bzw.
`lieferscheine/` - nicht beide im selben Ordner. Anhaenge, deren Name keinen
Hinweis gibt (z. B. `scan0001.pdf`), folgen weiterhin dem Mail-weiten Treffer
bzw. landen im `FALLBACK_FOLDER`.

## Sicherheit: Angriffsflaeche ueber Mail/Anhaenge

Mails und ihre Anhaenge kommen von aussen und sind grundsaetzlich nicht
vertrauenswuerdig. mail2nas geht deshalb mit mehreren Massnahmen defensiv
damit um:

- **Keine Pfad-Traversal ueber Dateinamen**: Anhang-Dateinamen werden vor dem
  Schreiben normalisiert und auf ein sicheres Zeichenset reduziert
  (`mail2nas/filenames.py::sanitize_filename`) - Zeichen wie `/`, `..` oder
  Steuerzeichen (auch ueber Unicode-Tricks wie fullwidth-Slashes oder
  Right-to-Left-Override) koennen so nicht aus dem Zielordner ausbrechen.
- **Keine Pfad-Traversal ueber Zielordner**: Auch die Zielordner aus
  `mapping.yaml` sind nicht vertrauenswuerdig - die Datei liegt auf dem Share
  und ist damit fuer jeden mit Schreibrechten aenderbar. `safe_join()` weist
  absolute Pfade und `..`-Komponenten ab und prueft zusaetzlich, dass das
  Ergebnis unterhalb von `STORAGE_ROOT` bleibt; abgewiesene Ziele landen im
  `FALLBACK_FOLDER` statt ausserhalb des Shares. (Ohne diese Pruefung wuerde
  bereits ein Eintrag wie `RE: /etc/cron.d` genuegen: in Python ersetzt ein
  absoluter rechter Operand beim Pfad-Join den kompletten Wurzelpfad.)
  Verschachtelte Ziele wie `rechnungen/2026` bleiben normal nutzbar.
- **Atomares Schreiben**: Anhaenge werden in eine temporaere Datei geschrieben
  und erst dann an ihren endgueltigen Namen umbenannt. Bricht die
  SMB-Verbindung mitten im Transfer ab, entsteht so keine abgeschnittene
  Datei, die spaeter faelschlich als vollstaendige Rechnung durchgeht.
- **Groessenlimits gegen Speicher-/Platten-Erschoepfung**: Die Groesse der
  gesamten Mail wird per `RFC822.SIZE` geprueft, *bevor* der Inhalt geladen
  wird (`MAX_MESSAGE_SIZE_MB`); einzelne Anhaenge werden zusaetzlich einzeln
  begrenzt (`MAX_ATTACHMENT_SIZE_MB`). Beides schuetzt vor einer einzelnen
  ueberdimensionierten Mail, die den Host/das Share volllaufen laesst.
- **Limit fuer Anhaenge pro Mail** (`MAX_ATTACHMENTS_PER_MESSAGE`): schuetzt
  vor Mails mit tausenden Mini-Anhaengen.
- **Quarantaene fuer ausfuehrbare Dateitypen** (`BLOCKED_EXTENSIONS`,
  `QUARANTINE_FOLDER`): Anhaenge mit Endungen wie `.exe`, `.js`, `.ps1`,
  `.jar`, `.lnk`, `.sh` usw. werden IMMER in einen separaten
  Quarantaene-Ordner geschrieben - unabhaengig davon, ob der Dateiname
  zufaellig auf ein Mapping-Stichwort passt. Das verhindert, dass ein
  Angreifer eine Datei einfach `Rechnung.exe` nennt, um sie in den
  Rechnungsordner zu schleusen. Die Datei wird dabei nicht geloescht,
  sondern bleibt fuer eine manuelle Pruefung erhalten - **niemals von dort
  oeffnen/ausfuehren**, ohne den Inhalt vorher zu verifizieren.
- **Kein automatisches Entpacken/Ausfuehren**: mail2nas speichert Anhaenge
  ausschliesslich als Rohbytes. ZIP-/Office-/PDF-Inhalte werden nicht
  entpackt, geparst oder ausgefuehrt - das eliminiert ganze Klassen von
  Angriffen (Zip-Bombs, Makro-Ausfuehrung, Parser-Exploits) von vornherein,
  verlagert die Verantwortung aber auf die Person, die die abgelegte Datei
  spaeter oeffnet (siehe Hinweis zu `.exe` oben).
- **TLS/Zertifikatspruefung fuer IMAP** ist per Default aktiv (`IMAP_SSL=true`,
  Standardport `993`) und nutzt den Python-Standard-`ssl`-Kontext inkl.
  Zertifikatsvalidierung.
- **Idempotenz statt Wiederholungs-DoS**: bereits verarbeitete Message-IDs
  werden in SQLite vermerkt, damit eine kaputte/boesartige Mail nicht bei
  jedem Zyklus erneut komplett verarbeitet wird.
- **Eine kaputte `mapping.yaml` legt den Dienst nicht lahm**: Da die Datei auf
  dem Share von Hand bearbeitet wird, ist eine halb geschriebene oder
  ungueltige Version nur eine Frage der Zeit. Statt die Ausnahme bis in die
  IMAP-Schleife durchschlagen zu lassen (was in einer Reconnect-Endlosschleife
  endete, in der gar nichts mehr archiviert wurde), wird der Fehler einmal
  geloggt und mit dem letzten funktionierenden Regelsatz weitergearbeitet.
- **Fail-fast beim Start**: Ist `STORAGE_ROOT` nicht vorhanden oder nicht
  beschreibbar, bricht der Dienst mit einer klaren Meldung ab, statt Anhaenge
  in das Dateisystem des Containers zu schreiben, wo sie mit dem naechsten
  Neustart verschwinden wuerden. Fehlerhafte Konfigurationswerte
  (`IMAP_MODE`, `FILENAME_PREFIX`, Zahlenwerte, Portbereich) werden beim Start
  benannt, statt still ein anderes Verhalten zu waehlen.

Diese Massnahmen reduzieren die Angriffsflaeche deutlich, ersetzen aber
keinen Virenscanner. Wer mail2nas produktiv gegen das offene Internet
betreibt, sollte zusaetzlich serverseitiges Antivirus/Spam-Filtering vor dem
IMAP-Postfach (z. B. beim Mail-Provider oder per vorgeschaltetem
Mailserver/ClamAV) einplanen.

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

Die Suite deckt unter anderem die oben beschriebenen Schutzmassnahmen ab
(Traversal-Versuche ueber Zielordner, Quarantaene, Groessen- und
Anzahl-Limits, kaputte `mapping.yaml`, Konfigurationsvalidierung).

`scripts/bootstrap.sh` enthaelt eine eingebettete Kopie aller Projektdateien
und wird generiert, nicht von Hand gepflegt. Nach Aenderungen an einer
eingebetteten Datei:

```bash
python3 scripts/regenerate-bootstrap.py          # neu erzeugen
python3 scripts/regenerate-bootstrap.py --check  # nur pruefen (fuer CI)
```

## Sicherheitshinweise

- `.env` niemals committen (steht in `.gitignore`) und mit restriktiven
  Dateirechten ablegen (`chmod 600 .env`). Das Proxmox-Helper-Skript und
  `scripts/proxmox/install.sh` setzen diese Rechte automatisch.
- Dediziertes IMAP-Konto mit App-Passwort statt Zugangsdaten eines
  Hauptpostfachs verwenden.
- Dedizierten SMB-Benutzer mit Schreibrechten nur auf die relevanten
  Zielordner einrichten, statt vollem Share-Zugriff.
- Im systemd-Betrieb liegen die SMB-Zugangsdaten in
  `/etc/mail2nas-smb-credentials` - Datei mit `chmod 600` nur fuer `root`
  lesbar halten.
- Siehe auch den ausfuehrlichen Abschnitt
  [Sicherheit: Angriffsflaeche ueber Mail/Anhaenge](#sicherheit-angriffsflaeche-ueber-mailanhaenge)
  zu Groessenlimits, Dateiendungs-Quarantaene und Pfad-Traversal-Schutz.
- Sicherheitsluecken bitte nicht als oeffentliches GitHub-Issue melden,
  siehe [SECURITY.md](SECURITY.md).

## Datenschutz (DSGVO)

mail2nas verarbeitet E-Mails und Anhaenge, die typischerweise
personenbezogene Daten enthalten (Namen, Adressen, Bankverbindungen in
Rechnungen/Lieferscheinen usw.). Wer das Tool einsetzt, ist im Sinne der
DSGVO fuer diese Verarbeitung verantwortlich. Ein paar Punkte, die dabei zu
beachten sind:

- **Datensparsamkeit im Log**: Es werden Betreff, Absenderadresse,
  Anhang-Dateinamen und Zielpfade geloggt (siehe `LOG_LEVEL`), nicht der
  Mailinhalt selbst. Trotzdem koennen Betreffzeilen personenbezogene Daten
  enthalten - Logs entsprechend absichern (Zugriff beschraenken, ggf.
  Aufbewahrungsfrist definieren).
- **Zugriffsbeschraenkung auf den Ziel-Share**: Nur Personen/Konten mit
  begruendetem Zugriff sollten Lese-/Schreibrechte auf den SMB-Share (und
  die darin abgelegten Dokumente) haben.
- **Verschluesselung**: IMAP-Verbindung laeuft per Default per TLS
  (`IMAP_SSL=true`). Fuer den SMB-Transportweg empfiehlt sich `vers=3.0`
  (unterstuetzt SMB-Verschluesselung) statt aelterer, unverschluesselter
  SMB-Versionen, sofern Server und Client das anbieten.
- **Auftragsverarbeitung**: Wird mail2nas fuer Mails Dritter betrieben (z. B.
  als Dienstleister), kann eine Verarbeitung im Sinne von Art. 28 DSGVO
  vorliegen - in diesem Fall einen Auftragsverarbeitungsvertrag (AVV) mit
  den Beteiligten pruefen.
- Dieses Projekt ist Software, keine Rechtsberatung - bei Unsicherheiten
  bitte den eigenen Datenschutzbeauftragten/eine Rechtsberatung
  hinzuziehen.

## Rechnungsarchivierung / GoBD-Hinweis

mail2nas legt Anhaenge unveraendert (Rohbytes, keine Konvertierung) mit
Datums-/Absender-Praefix im Dateinamen auf dem Ziel-Share ab. Das ist
nuetzlich fuer die Sortierung, **ersetzt aber keine GoBD-konforme
("revisionssichere") Rechnungsarchivierung**: Die "Grundsaetze zur
ordnungsmaessigen Fuehrung und Aufbewahrung von Buechern, Aufzeichnungen und
Unterlagen in elektronischer Form" (GoBD) verlangen fuer steuerlich relevante
Belege (u. a. Rechnungen) zusaetzlich:

- **Unveraenderbarkeit/Nachvollziehbarkeit** der Ablage (z. B. WORM-Storage,
  Versionierung mit Aenderungsprotokoll, oder ein dediziertes
  Dokumentenmanagement-/Archivsystem) - ein normaler, beschreibbarer
  SMB-Ordner erfuellt das alleine nicht.
- **Vollstaendigkeit**: mail2nas archiviert nur, was per Mail ankommt und
  einen Anhang hat - Papierbelege, Portale-Downloads o. ae. muessen separat
  erfasst werden.
- **Aufbewahrungsfristen** von aktuell 8 bzw. 10 Jahren (§ 147 AO), inkl.
  Backup-/Ausfallsicherheit ueber diesen Zeitraum.

mail2nas ist als **Zubringer/Sortier-Werkzeug** gedacht - fuer die
tatsaechliche steuerlich relevante Archivierung sollte der Ziel-Share (oder
ein nachgelagertes DMS) die oben genannten Anforderungen erfuellen. Im
Zweifel den Steuerberater/die Steuerberaterin zur konkreten Umsetzung
befragen.

## Haftungsausschluss

mail2nas ist ein privates Open-Source-Projekt, keine kommerzielle Software
und keine Rechts-, Steuer- oder Sicherheitsberatung. Es wird "wie besehen"
("as is"), ohne jegliche Gewaehrleistung bereitgestellt - siehe die
vollstaendige Haftungsausschluss-Klausel in der [LICENSE](LICENSE) (MIT).
Ergaenzend gilt:

- **Keine Garantie fuer Vollstaendigkeit oder Korrektheit der Zustellung.**
  mail2nas verarbeitet Mails automatisiert per Stichwort-Mapping; eine
  Fehlklassifizierung, ein verpasster Anhang (z. B. wegen eines nicht
  erkannten Formats, eines Netzwerk-/IMAP-Fehlers oder falscher
  Mapping-Konfiguration) oder ein Ausfall des Dienstes koennen nicht
  ausgeschlossen werden. Wer sich auf die vollstaendige, fristgerechte
  Archivierung geschaeftskritischer Dokumente (z. B. Rechnungen) verlassen
  muss, sollte zusaetzliche Kontrollen (Stichproben, Monitoring, Backups des
  Quell-Postfachs) vorsehen - siehe auch den Abschnitt zu
  [GoBD](#rechnungsarchivierung--gobd-hinweis) oben.
- **Keine Haftung fuer Datenverlust oder -beschaedigung** auf dem Ziel-Share,
  im Postfach oder in der Statusdatenbank, unabhaengig von der Ursache
  (Softwarefehler, Fehlkonfiguration, Ausfall der zugrundeliegenden
  Infrastruktur wie Proxmox/Docker/SMB/IMAP).
- **Keine Haftung fuer Sicherheitsvorfaelle** trotz der in
  [Sicherheit: Angriffsflaeche ueber Mail/Anhaenge](#sicherheit-angriffsflaeche-ueber-mailanhaenge)
  beschriebenen Massnahmen. Diese reduzieren bekannte Risiken, koennen aber
  keinen vollstaendigen Schutz garantieren (z. B. gegen bislang unbekannte
  Schwachstellen in verwendeten Bibliotheken/Basis-Images). Sicherheitsupdates
  (Docker-Base-Image, Python-Abhaengigkeiten, Betriebssystem der LXC) liegen
  in der Verantwortung der betreibenden Person.
- **Die Proxmox-/Installer-Skripte** (`scripts/proxmox/*.sh`,
  `scripts/bootstrap.sh`) greifen aktiv in die Zielumgebung ein (legen
  Container an, installieren Pakete, schreiben Dateien mit Zugangsdaten).
  Vor dem Einsatz in produktiven Proxmox-Umgebungen empfiehlt sich ein
  Testlauf in einer Nicht-Produktivumgebung.
- Nutzung erfolgt vollstaendig auf eigenes Risiko der betreibenden Person
  bzw. Organisation. Bei rechtlichen oder steuerlichen Unsicherheiten
  (insbesondere zu DSGVO- oder GoBD-Konformitaet des Gesamtaufbaus) bitte
  entsprechend fachkundigen Rat einholen - siehe
  [Datenschutz (DSGVO)](#datenschutz-dsgvo) und
  [GoBD-Hinweis](#rechnungsarchivierung--gobd-hinweis).

## Lizenz

MIT-Lizenz, siehe [LICENSE](LICENSE). Nutzung auf eigene Verantwortung, ohne
Gewaehrleistung - siehe insbesondere den
[Haftungsausschluss](#haftungsausschluss) sowie die Abschnitte zu
Datenschutz und GoBD oben, falls das Tool fuer geschaeftliche/steuerlich
relevante Zwecke eingesetzt wird.

## Updates einspielen

Updates brauchen **keine Neukonfiguration**. Weder Zugangsdaten noch
Mapping-Regeln muessen erneut eingegeben werden.

### Mit git installiert (Variante 1) - der einfache Weg

Ein Befehl, direkt vom Proxmox-Host aus:

```bash
pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"
```

Oder innerhalb der LXC (`pct enter <CTID>`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"
```

`update.sh` fragt nichts ab und braucht keine Zugangsdaten. Es legt vor dem
Update eine datierte Sicherung der `.env` an, holt den aktuellen Code, baut
das Image mit `--pull` neu (damit auch das Python-Basis-Image aktuelle
Sicherheitsupdates bekommt), startet den Dienst neu und raeumt alte Images
auf.

**Unangetastet bleiben dabei:**

| Was | Wo | Warum es das Update ueberlebt |
|---|---|---|
| Zugangsdaten & alle Einstellungen | `/opt/mail2nas/.env` | steht in `.gitignore`, wird von `git reset --hard` nicht beruehrt |
| Stichwort-Mapping | `mapping.yaml` auf dem SMB-Share | liegt gar nicht im Repo |
| Bereits verarbeitete Mails | Docker-Volume `state` | benanntes Volume, bleibt ueber Rebuilds bestehen - es wird nach dem Update nichts doppelt archiviert |

Bringt eine neue Version zusaetzliche Konfigurationsvariablen mit, greifen
dafuer automatisch die dokumentierten Defaults - eine aeltere `.env` bleibt
also gueltig und muss nicht angefasst werden. Wer die neuen Optionen nutzen
will, ergaenzt sie einfach in der `.env` und ruft
`docker compose up -d` auf.

Von Hand geht es genauso:

```bash
cd /opt/mail2nas
git fetch --depth 1 origin main && git reset --hard FETCH_HEAD
docker compose up -d --build
```

Ein erneuter Aufruf von `scripts/proxmox/install.sh` ist ebenfalls
gefahrlos: erkennt es eine vorhandene `.env` und bekommt keine Zugangsdaten
uebergeben, wechselt es automatisch in den Update-Modus und laesst die
Konfiguration unveraendert.

### Ohne git installiert (Variante 2)

- **Bootstrap-Skript erneut ausfuehren** (Variante A) - ueberschreibt alle
  Code-Dateien, laesst `.env` und die auf dem SMB-Share liegende
  `mapping.yaml` unangetastet. Danach:
  ```bash
  cd /opt/mail2nas && docker compose up -d --build
  ```
  (bzw. `systemctl restart mail2nas` im venv-Betrieb).
- **Neues Archiv per scp uebertragen** (Variante B) und das alte
  Verzeichnis ersetzen - `.env` vorher sichern, da sie nicht Teil des
  Archivs ist.

### Zurueckrollen

`update.sh` legt vor jedem Lauf eine Kopie der `.env` als
`.env.bak.<Zeitstempel>` an. Auf einen aelteren Codestand zurueck geht es
mit dem gewuenschten Commit:

```bash
cd /opt/mail2nas
git fetch --depth 50 origin main
git reset --hard <commit-sha>
docker compose up -d --build
```
