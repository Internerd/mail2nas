# mail2nas

Holt Mails per IMAP ab, sortiert Anhaenge anhand konfigurierbarer Stichwoerter
(Stichwort im Betreff -> Zielordner) und legt sie auf einem SMB-Share ab. Die
Zuordnungen werden ueber eine kleine, passwortgeschuetzte Weboberflaeche
gepflegt. Gedacht zum Betrieb als Container auf Proxmox (LXC/Docker), kann aber
genauso als einfacher systemd-Service laufen.

## Inhaltsverzeichnis

- [Funktionsweise](#funktionsweise)
- [Voraussetzungen](#voraussetzungen)
- [Installation, Variante 1: Proxmox-Helper-Skript (automatisch)](#installation-variante-1-proxmox-helper-skript-automatisch)
- [Installation, Variante 2: Proxmox ohne Git (manuelles Kopieren)](#installation-variante-2-proxmox-ohne-git-manuelles-kopieren)
- [Weiter mit Docker Compose](#weiter-mit-docker-compose)
- [Alternative ohne Docker (LXC + systemd)](#alternative-ohne-docker-lxc--systemd)
- [Wie mail2nas auf das Share zugreift](#wie-mail2nas-auf-das-share-zugreift)
- [Weboberflaeche](#weboberflaeche)
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

1. Verbindet sich per IMAP mit einem oder mehreren Postfaechern (IDLE-Push
   oder Polling, je Postfach einstellbar).
2. Liest ungelesene Mails, sucht im Betreff (optional auch im Mailtext)
   nach den konfigurierten Stichwoertern.
3. Die Zuordnungen werden **von oben nach unten** geprueft, die erste
   passende gewinnt und bestimmt den Zielordner unterhalb des SMB-Shares
   (z. B. `RE`/`Rechnung` -> `rechnungen/`, `LS`/`Lieferschein` ->
   `lieferscheine/`). Gross-/Kleinschreibung ist egal, `*` und `?` sind als
   Platzhalter erlaubt, und eine Zuordnung kann auf ein einzelnes Postfach
   beschraenkt werden. Ohne Treffer landen Anhaenge im `FALLBACK_FOLDER`
   (Default: `unsorted/`).
4. Anhaenge werden mit Datums-/Absender-Praefix gespeichert, Namenskollisionen
   werden automatisch durch einen Zaehler-Suffix vermieden.
5. Die Mail wird als gelesen markiert (und optional in einen
   `IMAP_PROCESSED_FOLDER` verschoben). Zusaetzlich wird die Message-ID in
   einer lokalen SQLite-Datenbank vermerkt, damit nichts doppelt verarbeitet
   wird, selbst wenn das `\Seen`-Flag von woanders zurueckgesetzt wird.
6. Die Zuordnungen liegen als `mapping.yaml` auf dem SMB-Share und werden bei
   jedem Zyklus neu eingelesen - Anpassungen wirken ohne Neustart/Redeploy.
   Gepflegt werden sie in der [Weboberflaeche](#weboberflaeche); die Datei
   bleibt dabei das Original und ist im Notfall auch von Hand editierbar.

Der Zugriff auf die Freigabe laeuft standardmaessig **direkt per SMB aus der
Anwendung heraus**: es wird nichts gemountet, weder im Container noch auf dem
Proxmox-Host. Warum das so ist und welche Alternative es gibt, steht unter
[Wie mail2nas auf das Share zugreift](#wie-mail2nas-auf-das-share-zugreift).

## Voraussetzungen

- Ein IMAP-Postfach (am besten ein dediziertes Konto/App-Passwort, keine
  Zugangsdaten eines persoenlichen Postfachs).
- Ein SMB-Share mit einem Benutzer, der Schreibrechte auf die Zielordner hat.
- Ein Proxmox-Host mit einer LXC (Debian/Ubuntu-Template) oder VM, auf der
  entweder Docker+Compose oder Python 3.11+ verfuegbar ist.
- Fuer die Weboberflaeche: ein freier Port (Default 8080) und ein Browser im
  selben Netz. Sie ist optional (`WEB_ENABLED=false`).
- **Kein** Mount und damit auch kein `cifs-utils` noetig - mail2nas spricht
  SMB selbst. Nur beim optionalen `STORAGE_BACKEND=local` muss das Share
  vorher vom Betriebssystem eingebunden sein.
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
2. Fragt anschliessend nach den IMAP- und SMB-Zugangsdaten, dem Mapping-Pfad
   und Fallback-Ordner sowie danach, ob die Weboberflaeche aktiviert werden
   soll (mit Port und Startpasswort).
3. Legt eine neue, unprivilegierte Debian-12-LXC an (`pct create`).
4. Installiert darin Docker und git, klont dieses Repository, schreibt die
   `.env` aus deinen Eingaben und startet den Dienst (`docker compose up -d`).
   Es wird kein Share gemountet - weder in der LXC noch auf dem Host.
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

Danach fehlen nur noch die Stichwort-Zuordnungen. Mit aktivierter
Weboberflaeche geht das im Browser unter `http://<container-ip>:8080/` - das
Skript zeigt die Adresse am Ende an. Ohne Weboberflaeche stattdessen
`config/mapping.example.yaml` (liegt im Container unter
`/opt/mail2nas/config/`) als `mapping.yaml` auf die Wurzel des SMB-Shares
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
apt-get update && apt-get install -y docker.io docker-compose-plugin

cd /opt/mail2nas
cp .env.example .env
$EDITOR .env    # IMAP- und SMB-Zugangsdaten eintragen

docker compose up -d --build
docker compose logs -f
```

Es ist nichts zu mounten: mit dem Default `STORAGE_BACKEND=smb` verbindet sich
mail2nas selbst mit `//SMB_HOST/SMB_SHARE`. Beim Start wird einmal testweise
geschrieben, damit falsche Zugangsdaten oder fehlende Schreibrechte sofort im
Log stehen statt erst bei der ersten Mail.

Die Stichwort-Zuordnungen werden danach in der
[Weboberflaeche](#weboberflaeche) gepflegt: `http://<host>:8080/`, Anmeldung
mit `WEB_PASSWORD` aus der `.env`.

Wer die Oberflaeche nicht will (`WEB_ENABLED=false`), legt `mapping.yaml`
stattdessen von Hand auf die Wurzel des Shares (Pfad relativ dazu ist in
`MAPPING_PATH` konfigurierbar). Da das Share hier nirgends gemountet ist, geht
das ueber einen beliebigen SMB-Client - Windows-Explorer, die Dateiverwaltung
des NAS, oder `smbclient`:

```bash
smbclient //nas.local/Belege -U mail2nas -c 'put config/mapping.example.yaml mapping.yaml'
```

### Variante mit bereits gemountetem Share

Ist das Share ohnehin schon vom Betriebssystem eingebunden (eigener
fstab-Eintrag, Bind-Mount vom Proxmox-Host), kann mail2nas stattdessen einfach
in dieses Verzeichnis schreiben. Dann `STORAGE_BACKEND=local` setzen, `NAS_PATH`
auf das gemountete Verzeichnis zeigen lassen und die Compose-Override-Datei
mitgeben, die den Bind-Mount ergaenzt:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

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

apt-get update && apt-get install -y python3-venv python3-pip
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# Systembenutzer fuer den Dienst anlegen
useradd --system --home /opt/mail2nas --shell /usr/sbin/nologin mail2nas || true
```

Auch hier wird nichts gemountet - die SMB-Zugangsdaten stehen in der `.env`,
die nur dem Dienstbenutzer gehoert. Danach `.env` anlegen:

```bash
cp .env.example .env
$EDITOR .env
chown -R mail2nas:mail2nas /opt/mail2nas
chmod 600 /opt/mail2nas/.env
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

Die Weboberflaeche laeuft im systemd-Betrieb im selben Prozess mit, sobald
`WEB_ENABLED=true` in der `.env` steht - ein zweiter Dienst ist nicht noetig.
Alternativ `mapping.yaml` wie im Docker-Abschnitt beschrieben von Hand auf die
Wurzel der Freigabe (bzw. den konfigurierten `MAPPING_PATH`) legen.

Soll stattdessen ein bereits gemountetes Verzeichnis verwendet werden:
`STORAGE_BACKEND=local` und `STORAGE_ROOT=/mnt/nas` in der `.env` setzen, und
in der Unit `After=`/`RequiresMountsFor=` auf den Mountpunkt zeigen lassen.

## Wie mail2nas auf das Share zugreift

Standardmaessig (`STORAGE_BACKEND=smb`) spricht mail2nas das SMB-Protokoll
**direkt aus der Anwendung**. Es wird nirgends ein Dateisystem eingehaengt:
nicht im Docker-Container, nicht in der LXC und nicht auf dem Proxmox-Host.

Der Grund ist eine harte Kernel-Grenze: CIFS ist nicht als `FS_USERNS_MOUNT`
markiert, und `mount(2)` ist fuer solche Dateisysteme aus dem User-Namespace
einer **unprivilegierten LXC** verboten. Das gilt unabhaengig davon, wer den
Mount versucht:

- Dockers `local`-Volume-Treiber mit `type: cifs` setzt den `mount()`-Syscall
  selbst ab und scheitert mit der wenig aussagekraeftigen Meldung
  `failed to mount local volume: ... : invalid argument`. Zusaetzlich landet
  das SMB-Passwort dabei dauerhaft in den Volume-Metadaten des Docker-Daemons
  und ist per `docker volume inspect` auslesbar.
- `mount.cifs` innerhalb der LXC scheitert am selben Syscall - auch mit
  gelockerten AppArmor-Profilen.

Frueher wurde deshalb auf dem Proxmox-Host gemountet und das Verzeichnis per
Bind-Mount in die LXC gereicht. Das funktioniert, hat aber zwei Nachteile, die
sich nicht wegkonfigurieren lassen:

- Der Mountpunkt ist fuer **jeden mit Root-Shell auf dem Node** sichtbar, nicht
  nur fuer diesen einen Container.
- Die SMB-Zugangsdaten muessen in einer Datei auf dem Host liegen. Wer dort
  root wird, hat damit Zugriff auf die gesamte Freigabe - und die Datei landet
  in jedem Host-Backup.

Mit dem SMB-Backend entfaellt beides. Die Zugangsdaten stehen nur noch in der
`.env` der LXC (`chmod 600`), und der Zugriff endet an der Container-Grenze:

```
mail2nas (im Container)  --SMB3-->  //nas/share
        keine Mounts, kein cifs-utils, keine Host-Konfiguration
```

Weitere Eigenschaften:

- Verbindungen werden bei Fehlern automatisch einmal neu aufgebaut - ein
  NAS-Neustart oder eine abgelaufene Session beendet den Dienst nicht.
- Anhaenge werden unter einem temporaeren Namen geschrieben und erst danach
  umbenannt. Ein abgebrochener Transfer hinterlaesst dadurch nie eine
  abgeschnittene Datei unter einem Namen, der wie eine vollstaendige Rechnung
  aussieht.
- Die Verbindung ist per Default SMB3-verschluesselt (`SMB_ENCRYPT=true`).
  Aeltere NAS-Firmware kann das ablehnen - dann `SMB_ENCRYPT=false` setzen.
- Mit `SMB_ROOT` laesst sich alles auf einen Unterordner der Freigabe
  begrenzen.

### Wann `STORAGE_BACKEND=local` sinnvoll ist

Wenn das Share aus anderen Gruenden ohnehin schon vom Betriebssystem
eingebunden ist, oder wenn statt SMB etwas ganz anderes darunterliegt (NFS,
lokale Platte, ZFS-Dataset). Dann schreibt mail2nas einfach in das
konfigurierte Verzeichnis `STORAGE_ROOT`, und um den Mount kuemmert sich das
System. Fuer Docker ergaenzt `docker-compose.local.yml` den noetigen
Bind-Mount:

```
Host   /etc/fstab:  //nas/share  ->  /mnt/mail2nas-<CTID>   (cifs)
                          |
            pct -mp0 Bind-Mount   ->  /mnt/nas   (in der LXC)
                          |
   docker-compose.local.yml       ->  /mnt/nas   (im Container)
```

In einer unprivilegierten LXC muss der `fstab`-Eintrag auf dem Host dann
`uid=101000,gid=101000` setzen: der Container laeuft als uid 1000, und Proxmox
bildet den User-Namespace ab 100000 ab. Ohne das gehoerten die Dateien im
Container niemandem und waeren nicht beschreibbar. Bei einem privilegierten
Container bleibt es bei `uid=1000`.

## Weboberflaeche

Eine kleine, passwortgeschuetzte Seite zum Pflegen der Stichwort-Zuordnungen -
damit die `mapping.yaml` nicht mehr von Hand bearbeitet werden muss. Sie laeuft
im selben Prozess wie der Archiver mit, es ist also kein zweiter Dienst und
kein zweiter Container noetig.

```
http://<host-oder-container-ip>:8080/
```

Was sie kann:

- **Stichwort zuordnen**: Stichwort eintippen und einen Zielordner aus einer
  Liste der Ordner waehlen, die auf der Freigabe tatsaechlich existieren. Statt
  einen Pfad zu tippen und sich zu vertippen, waehlt man aus - genau das ist
  der Punkt der Oberflaeche. Ein neuer Ordner kann direkt angelegt werden.
- **Reihenfolge festlegen**: Die Liste wird von oben nach unten geprueft, die
  erste passende Zuordnung gewinnt. Mit den Pfeilen `↑`/`↓` laesst sich jede
  Zeile verschieben - so kommt z. B. `Rechnungskorrektur` ueber `RE`.
- **Zuordnung aendern oder loeschen**: pro Zeile ein Auswahlfeld und ein
  Loeschen-Knopf. Der Ordner auf der Freigabe bleibt beim Loeschen bestehen,
  entfernt wird nur die Regel.
- **Postfach je Zuordnung**: sobald mehr als ein Postfach eingerichtet ist,
  hat jede Zeile zusaetzlich ein Auswahlfeld - „alle Postfaecher" oder genau
  eines.
- **Konfiguration**: Postfaecher anlegen/aendern/loeschen und die
  Mapping-Datei verschieben, siehe unten.
- **Passwort aendern**: nach dem Login unter „Passwort". Dabei werden alle
  anderen angemeldeten Sitzungen abgemeldet.

Aenderungen landen sofort in der `mapping.yaml` auf der Freigabe und wirken
beim naechsten Durchlauf des Archivers - kein Neustart noetig.

### Stichwoerter, Reihenfolge und Platzhalter

- **Gross-/Kleinschreibung ist egal.** `re`, `RE` und `Re` sind dasselbe.
- **Gesucht wird als Teilstring**, nicht als ganzes Wort: `RE` passt auch auf
  „VORAB-RECHNUNG". Wer das nicht will, nimmt ein laengeres Stichwort.
- **`*` steht fuer beliebig viele Zeichen, `?` fuer genau eines.** Beispiele:
  | Stichwort | passt auf | passt nicht auf |
  |---|---|---|
  | `RE*` | „Ihre RE-4711" | „Angebot" |
  | `RE*2026` | „RE-4711 vom 03.2026" | „RE-4711 vom 03.2025" |
  | `Rechn?ng` | „Rechnung", „Rechnang" | „Rechnuung" |

  Alle anderen Sonderzeichen sind normale Zeichen - `RE.` sucht woertlich
  nach „RE." und nicht nach einem regulaeren Ausdruck. Maximal 5 Platzhalter
  pro Stichwort.
- **Die Reihenfolge entscheidet.** Frueher gewann automatisch das laengere
  Stichwort; jetzt steht die Prioritaet explizit in der Liste und ist mit den
  Pfeilen aenderbar. Eine bestehende `mapping.yaml` im alten Format wird genau
  in diese Reihenfolge uebernommen (laengstes Stichwort zuerst), es aendert
  sich also nichts an der Einsortierung.

### Mehrere Postfaecher

Unter „Konfiguration" lassen sich beliebig viele IMAP-Postfaecher anlegen, mit
je eigenem Server, Ordner und Abrufmodus. Jedes bekommt einen eigenen
Verbindungs-Thread, damit ein Postfach im IDLE-Modus die anderen nicht
blockiert. Ein Postfach kann pausiert (`aktiv` aus) statt geloescht werden.

Jede Zuordnung gilt wahlweise fuer alle Postfaecher oder nur fuer eines. Wird
ein Postfach geloescht, bleiben seine Zuordnungen bestehen, greifen aber nicht
mehr - die Oberflaeche zeigt sie dann als „(geloeschtes Postfach)".

Aenderungen an einem Postfach greifen innerhalb weniger Sekunden; die
betroffene IMAP-Verbindung wird dafuer neu aufgebaut, die anderen laufen
weiter. Reines Umbenennen loest keinen Reconnect aus.

Die erste Konfiguration kommt aus den `IMAP_*`-Variablen der `.env`: daraus
wird beim allerersten Start ein Postfach angelegt. Danach gilt die Datenbank,
und die Variablen werden ignoriert - auch wenn das letzte Postfach in der
Oberflaeche geloescht wurde, kommt es nicht aus der `.env` zurueck.

### Mapping-Datei verschieben

Unter „Konfiguration" laesst sich der Pfad der `mapping.yaml` (relativ zur
Archiv-Wurzel) aendern. Die vorhandene Datei wird dabei an den neuen Ort
kopiert und am alten geloescht; der Archiver zieht innerhalb weniger Sekunden
nach. Pfade ausserhalb der Archiv-Wurzel werden abgelehnt.

### Passwort

`WEB_PASSWORD` in der `.env` ist das **Startpasswort**. Beim ersten Start wird
es gehasht (scrypt) in der lokalen State-Datenbank abgelegt; ab dann gilt der
gespeicherte Wert und `WEB_PASSWORD` wird ignoriert - eine Aenderung in der
Oberflaeche ueberlebt also Neustarts und Updates. Mindestlaenge 8 Zeichen.

Das Passwort in der `.env` nach der ersten Anmeldung zu aendern bringt nichts
mehr; wer es wirklich zuruecksetzen muss, loescht den Eintrag in der
State-Datenbank:

```bash
docker compose exec -T mail2nas python - <<'EOF'
import sqlite3
conn = sqlite3.connect("/data/state.db")
conn.execute("DELETE FROM settings WHERE key = 'web_password_hash'")
conn.commit()
EOF
docker compose restart
```

Danach gilt wieder das `WEB_PASSWORD` aus der `.env`.

### Sicherheit

Die Oberflaeche ist fuer das eigene LAN gedacht und entsprechend gebaut:

- Ein Passwort, keine Benutzerverwaltung. Nach 5 Fehlversuchen ist die
  Anmeldung fuer eine Minute gesperrt (pro IP).
- Session-Cookie mit `HttpOnly` und `SameSite=Lax`, CSRF-Token in jedem
  Formular, Sitzungsdauer 12 Stunden.
- Kein JavaScript, keine externen Ressourcen, strikte Content-Security-Policy.
- Zielordner werden genauso geprueft wie beim Archiver: `..` und absolute
  Pfade werden abgelehnt, es kann also auch ueber die Oberflaeche nichts
  ausserhalb der Archiv-Wurzel angelegt werden.

**Nicht direkt aus dem Internet erreichbar machen.** Es gibt keine
TLS-Terminierung und keine Zwei-Faktor-Authentisierung. Wer von aussen
zugreifen will, nimmt VPN oder einen Reverse-Proxy mit HTTPS davor - und setzt
dann `WEB_COOKIE_SECURE=true`, damit das Session-Cookie nur noch ueber TLS
gesendet wird.

Abschalten laesst sich das Ganze mit `WEB_ENABLED=false`; die `mapping.yaml`
ist dann wieder ausschliesslich von Hand zu pflegen.

`GET /healthz` antwortet ohne Anmeldung mit `ok` - praktisch fuer ein
Monitoring-Check.

## Konfiguration (Environment-Variablen)

| Variable | Beschreibung | Default |
|---|---|---|
| `IMAP_HOST` / `IMAP_PORT` / `IMAP_SSL` | IMAP-Server des **ersten** Postfachs; danach in der Oberflaeche gepflegt | - / `993` / `true` |
| `IMAP_USER` / `IMAP_PASSWORD` | IMAP-Login des ersten Postfachs | - |
| `IMAP_FOLDER` | Zu ueberwachender Ordner des ersten Postfachs | `INBOX` |
| `IMAP_PROCESSED_FOLDER` | Optional: Zielordner fuer verarbeitete Mails | leer (nur `\Seen`) |
| `IMAP_MODE` | `idle` (Push) oder `poll` | `poll` |
| `POLL_INTERVAL_SECONDS` | Intervall im Poll-Modus bzw. IDLE-Refresh | `300` |
| `STORAGE_BACKEND` | `smb` (direkt per SMB, nichts gemountet) oder `local` (in ein gemountetes Verzeichnis schreiben) | `local` |
| `SMB_HOST` / `SMB_SHARE` | NAS und Freigabename, nur bei `STORAGE_BACKEND=smb` | - |
| `SMB_USER` / `SMB_PASSWORD` | SMB-Login mit Schreibrechten auf die Zielordner | - |
| `SMB_DOMAIN` | Domain/Workgroup, leer lassen wenn nicht noetig | leer |
| `SMB_PORT` | Port des SMB-Servers | `445` |
| `SMB_ROOT` | Unterordner innerhalb der Freigabe, unter dem alles abgelegt wird | leer (Wurzel) |
| `SMB_ENCRYPT` | SMB3-Verschluesselung erzwingen (`false` fuer aeltere Server) | `true` |
| `STORAGE_ROOT` | Wurzelverzeichnis des gemounteten Shares, nur bei `STORAGE_BACKEND=local` | `/mnt/nas` |
| `MAPPING_PATH` | Pfad zur `mapping.yaml`, relativ zur Archiv-Wurzel; spaeter in der Oberflaeche aenderbar | `mapping.yaml` |
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
| `NAS_PATH` | Nur mit `docker-compose.local.yml`: Verzeichnis des Docker-Hosts, das nach `/mnt/nas` im Container gebunden wird | `/mnt/nas` |
| `WEB_ENABLED` | [Weboberflaeche](#weboberflaeche) zum Pflegen der Zuordnungen starten | `false` |
| `WEB_HOST` / `WEB_PORT` | Adresse und Port der Weboberflaeche | `0.0.0.0` / `8080` |
| `WEB_PASSWORD` | Startpasswort (mind. 8 Zeichen); nur bis zur ersten Aenderung in der Oberflaeche relevant | - |
| `WEB_COOKIE_SECURE` | Session-Cookie nur ueber HTTPS senden (hinter einem TLS-Reverse-Proxy auf `true`) | `false` |
| `DRY_RUN` | Nichts schreiben, nur loggen | `false` |
| `LOG_LEVEL` | Log-Level | `INFO` |

**Die `IMAP_*`-Variablen sind Startwerte.** Beim allerersten Start wird daraus
das erste Postfach angelegt; danach gilt die in der Oberflaeche gepflegte
Konfiguration und die Variablen werden ignoriert. Dasselbe gilt fuer
`WEB_PASSWORD` und `MAPPING_PATH`. Alles andere in dieser Tabelle wird bei
jedem Start aus der `.env` gelesen.

**Zum Default von `STORAGE_BACKEND`:** Der Default ist bewusst `local`, damit
eine bestehende Installation, deren `.env` diese Variable noch nicht kennt,
nach einem Update unveraendert mit ihrem gemounteten Share weiterlaeuft. Alle
Installationswege (`.env.example`, die Skripte in `scripts/`) setzen den Wert
ausdruecklich auf `smb`.

**Die SMB-Zugangsdaten stehen in der `.env`** (`chmod 600`, nur in der LXC bzw.
auf dem Zielsystem). Auf dem Proxmox-Host liegen keine Zugangsdaten und kein
Mount mehr - siehe
[Wie mail2nas auf das Share zugreift](#wie-mail2nas-auf-das-share-zugreift).

## Mapping-Datei und Mehrfach-Anhaenge

Normalerweise wird diese Datei ueber die [Weboberflaeche](#weboberflaeche)
gepflegt. Sie bleibt aber eine gewoehnliche YAML-Datei auf der Freigabe und
laesst sich genauso von Hand bearbeiten - die Oberflaeche schreibt exakt
dieses Format:

```yaml
version: 2
rules:
  - keyword: Rechnungskorrektur
    folder: korrekturen
  - keyword: "RE*"
    folder: rechnungen
  - keyword: Bestellung
    folder: einkauf
    account: "2"        # nur fuer Postfach mit dieser ID
```

Die Liste wird von oben nach unten geprueft, die erste passende Zuordnung
gewinnt. `account` ist optional; fehlt es, gilt die Zuordnung fuer alle
Postfaecher. Zu Platzhaltern und Reihenfolge siehe
[Weboberflaeche](#stichwoerter-reihenfolge-und-platzhalter).

**Aeltere Dateien werden weiter gelesen.** Das frueheres Flachformat

```yaml
RE: rechnungen
Lieferschein: lieferscheine
```

wird beim Laden uebernommen, laengstes Stichwort zuerst - also genau die
Prioritaet, die diese Version implizit hatte. Umgeschrieben wird die Datei
erst, wenn in der Oberflaeche etwas gespeichert wird.

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
- **Nichts passiert**: pruefen, ob `mapping.yaml` unter dem konfigurierten
  `MAPPING_PATH` in der Wurzel der Freigabe liegt (beim Start wird geloggt,
  wie viele Regeln geladen wurden - `Loaded N mapping rule(s)`), und ob im
  IMAP-Ordner ueberhaupt ungelesene Mails liegen.
- **Mail landet immer im Fallback-Ordner**: Stichwort in `mapping.yaml`
  pruefen (Betreff-Text muss das Stichwort als Teilstring enthalten, Gross-/
  Kleinschreibung ist egal); bei Bedarf `MATCH_BODY=true` setzen, um auch
  den Mailtext zu durchsuchen.
- **Mail wird doppelt verarbeitet**: sollte durch die SQLite-Statusdatei
  (`STATE_DB_PATH`) verhindert werden. Bei einem kompletten Neuaufsetzen des
  Containers/Diensts bleibt diese Datei erhalten, solange das zugehoerige
  Volume (`state`) bzw. der Pfad im systemd-Betrieb nicht geloescht wird.
- **`Cannot archive to //... over SMB`**: der Startup-Schreibtest ist
  fehlgeschlagen, der Dienst startet bewusst nicht. Die Meldung enthaelt den
  Original-Fehler des Servers:
  - `STATUS_LOGON_FAILURE` -> `SMB_USER`/`SMB_PASSWORD`/`SMB_DOMAIN` pruefen.
  - `STATUS_BAD_NETWORK_NAME` bzw. `No such file or directory` auf einem Pfad
    direkt unterhalb der Freigabe -> `SMB_SHARE` (oder `SMB_ROOT`) stimmt
    nicht, Gross-/Kleinschreibung beachten.
  - `STATUS_ACCESS_DENIED` -> der Benutzer darf nicht schreiben (ggf. nur im
    per `SMB_ROOT` gesetzten Unterordner).
  - Timeouts/`Connection refused` -> `SMB_HOST`/`SMB_PORT` und Firewall.
  - Meldungen rund um Verschluesselung/Dialekt -> `SMB_ENCRYPT=false` testen,
    aeltere NAS-Firmware unterstuetzt SMB3-Encryption nicht.
- **`STORAGE_ROOT ... does not exist`** (nur bei `STORAGE_BACKEND=local`): das
  Share ist nicht gemountet. Entweder den Mount reparieren oder auf
  `STORAGE_BACKEND=smb` umstellen, dann wird kein Mount mehr gebraucht.
- **Weboberflaeche nicht erreichbar**: `docker compose ps` zeigt, ob der Port
  veroeffentlicht ist; `docker compose logs | grep "Web UI"` zeigt, ob sie
  ueberhaupt gestartet ist (`WEB_ENABLED=true` gesetzt?). `curl
  http://localhost:8080/healthz` muss `ok` liefern. Steht im Log
  `Web UI cannot listen on ...`, ist der Port belegt - `WEB_PORT` aendern.
- **Passwort der Weboberflaeche vergessen**: siehe
  [Weboberflaeche -> Passwort](#passwort).
- **Ein Postfach wird nicht abgeholt**: unter „Konfiguration" pruefen, ob es
  auf `aktiv` steht. Im Log steht je Postfach eine Zeile
  `Account <Name> <benutzer>: watching INBOX on <host>`; Verbindungsfehler
  erscheinen mit demselben Praefix, sodass sich bei mehreren Postfaechern
  zuordnen laesst, welches betroffen ist.
- **Mail landet trotz passender Zuordnung im Fallback**: die Reihenfolge
  pruefen (eine weiter oben stehende Zuordnung kann zuerst greifen) und ob die
  Zuordnung auf ein anderes Postfach eingeschraenkt ist.
- **`No enabled IMAP account configured`**: es ist kein Postfach aktiv - in der
  Oberflaeche unter „Konfiguration" eines anlegen oder aktivieren.
- **`Zu viele Fehlversuche`**: die Anmeldesperre laeuft nach einer Minute von
  selbst ab.

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
- Die Weboberflaeche gehoert ins eigene LAN, nicht ins Internet: ein Passwort,
  kein TLS von Haus aus. Details unter [Weboberflaeche](#weboberflaeche). Das
  Startpasswort aus der `.env` nach der ersten Anmeldung dort aendern.
- **Die State-Datenbank enthaelt IMAP-Passwoerter im Klartext.** Seit die
  Postfaecher in der Oberflaeche gepflegt werden, liegen sie dort statt nur in
  der `.env` - sie muessen ja zum Anmelden verwendbar sein, ein Hash geht
  nicht. mail2nas setzt die Datei beim Start auf `chmod 600`; sie verdient
  denselben Schutz wie die `.env`:
  - Das Docker-Volume `state` (bzw. `STATE_DB_PATH` im systemd-Betrieb) nicht
    breiter freigeben als noetig.
  - **Backups des Volumes enthalten die Passwoerter** - entsprechend ablegen.
  - Wer Zugriff auf die Weboberflaeche hat, kann Postfaecher anlegen und damit
    Mails von beliebigen Servern abholen lassen. Das Passwort dort ist also
    kein „nur Zuordnungen"-Passwort.
- Die SMB-Zugangsdaten stehen ausschliesslich in der `.env` des Zielsystems.
  Es liegen keine Zugangsdaten und kein Mount auf dem Proxmox-Host, also
  bekommt auch niemand ueber eine Host-Shell oder ein Host-Backup Zugriff auf
  die Freigabe. Nur beim optionalen `STORAGE_BACKEND=local` gilt das nicht:
  dort ist der Mountpunkt fuer jeden mit Root-Shell auf dem Node sichtbar und
  die Credentials-Datei liegt auf dem Host.
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

### Kurzfassung

| Installiert per | Update-Befehl |
|---|---|
| Helper-Skript / git (Variante 1) | `pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"` |
| Bootstrap-Skript (Variante 2A) | `bootstrap.sh` erneut ausfuehren, dann `docker compose up -d --build` |
| scp/tar (Variante 2B) | Archiv neu uebertragen, `.env` behalten, dann `docker compose up -d --build` |
| systemd/venv | Code aktualisieren, `venv/bin/pip install -r requirements.txt`, `systemctl restart mail2nas` |

Nach dem Update einmal ins Log schauen (`docker compose logs -f`): dort steht,
wie viele Zuordnungen geladen wurden und welche Postfaecher ueberwacht werden.

### Was beim Update automatisch migriert wird

- **Die `mapping.yaml` im alten Flachformat** wird weiter gelesen und in die
  gleiche Prioritaet uebernommen (laengstes Stichwort zuerst). Die Datei wird
  erst umgeschrieben, wenn in der Oberflaeche etwas gespeichert wird - bis
  dahin ist ein Downgrade auf eine aeltere Version problemlos moeglich.
- **Das erste Postfach** wird beim ersten Start nach dem Update aus den
  `IMAP_*`-Variablen der bestehenden `.env` angelegt. Es ist danach unter
  „Konfiguration" sichtbar und wird ab dann von dort gepflegt.
- **Neue Konfigurationsvariablen** greifen mit ihren Defaults; eine alte `.env`
  bleibt gueltig. Insbesondere bleibt `WEB_ENABLED` ohne Eintrag auf `false` -
  wer die Weboberflaeche will, ergaenzt nach dem Update:
  ```
  WEB_ENABLED=true
  WEB_PASSWORD=mindestens-8-zeichen
  ```
  und startet mit `docker compose up -d` neu.
- **`STORAGE_BACKEND`** bleibt ohne Eintrag auf `local`, eine bestehende
  Installation mit gemountetem Share laeuft also unveraendert weiter.
  `update.sh` haengt in dem Fall automatisch `docker-compose.local.yml` an.

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
| SMB-Zugangsdaten & alle .env-Einstellungen | `/opt/mail2nas/.env` | steht in `.gitignore`, wird von `git reset --hard` nicht beruehrt |
| Stichwort-Zuordnungen | `mapping.yaml` auf dem SMB-Share | liegt gar nicht im Repo |
| Postfaecher, Passwort der Weboberflaeche, bereits verarbeitete Mails | Docker-Volume `state` | benanntes Volume, bleibt ueber Rebuilds bestehen - es wird nach dem Update nichts doppelt archiviert |

Das Volume `state` ist damit das einzige, was ausser der `.env` gesichert
werden muss - und es enthaelt IMAP-Passwoerter, siehe
[Sicherheitshinweise](#sicherheitshinweise).

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

Wer `STORAGE_BACKEND=local` verwendet, haengt dabei die Override-Datei mit an
(`-f docker-compose.yml -f docker-compose.local.yml`), sonst fehlt der
Bind-Mount des Shares. `update.sh` erkennt das anhand der `.env` selbst.

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
