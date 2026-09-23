# mail2nas

Holt Mails per IMAP ab, sortiert die Anhaenge anhand von Stichwoertern in
Ordner auf dem NAS (SMB) und druckt auf Wunsch mit. Dazu kommen Scans, die ein
Kopierer direkt in einen Ordner legt ("Scan to Folder"), und Adressen wie
`drucker@firma.de`, an die man einfach etwas schickt, damit es ausgedruckt
wird.

**Eingerichtet wird alles in der Weboberflaeche** - Postfaecher,
NAS-Freigaben, Zuordnungen, Drucker, Adressen, Abholordner und alle
Einstellungen. Die Installation fragt nach keinem einzigen Passwort; die
Konfiguration liegt in einer Datenbank im Container, nicht in Dateien und nicht
auf dem NAS. Gedacht fuer eine LXC auf Proxmox, laeuft aber ueberall, wo
Docker laeuft.

## Inhaltsverzeichnis

- [Funktionsweise](#funktionsweise)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Erste Einrichtung](#erste-einrichtung)
- [Die Weboberflaeche](#die-weboberflaeche)
- [Archive: wohin abgelegt wird](#archive-wohin-abgelegt-wird)
- [Drucken](#drucken)
- [Abholordner (Scan-to-Folder)](#abholordner-scan-to-folder)
- [Wo die Konfiguration liegt](#wo-die-konfiguration-liegt)
- [Updates](#updates)
- [Kommandozeile](#kommandozeile)
- [Sicherheit: Angriffsflaeche ueber Mail/Anhaenge](#sicherheit-angriffsflaeche-ueber-mailanhaenge)
- [Betrieb & Troubleshooting](#betrieb--troubleshooting)
- [Bekannte Grenzen](#bekannte-grenzen)
- [Tests und Entwicklung](#tests-und-entwicklung)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Datenschutz (DSGVO)](#datenschutz-dsgvo)
- [Rechnungsarchivierung / GoBD-Hinweis](#rechnungsarchivierung--gobd-hinweis)
- [Haftungsausschluss](#haftungsausschluss)
- [Lizenz](#lizenz)

## Funktionsweise

1. mail2nas ueberwacht ein oder mehrere IMAP-Postfaecher (IDLE-Push oder
   Polling, je Postfach einstellbar) und liest die ungelesenen Mails.
2. Jeder Anhang wird zuerst anhand **seines eigenen Dateinamens** gegen die
   Zuordnungen geprueft, dann anhand des Betreffs (auf Wunsch auch des
   Mailtexts). Die Liste wird **von oben nach unten** geprueft, die erste
   passende Zuordnung gewinnt und bestimmt den Zielordner - z. B.
   `Rechnung*` -> `rechnungen/`. Gross-/Kleinschreibung ist egal, `*` und `?`
   sind Platzhalter, eine Zuordnung kann auf ein Postfach beschraenkt werden.
   Ohne Treffer landet der Anhang im Ordner fuer Unsortiertes.
3. Der Anhang wird mit Datum und Absender im Namen auf dem NAS abgelegt -
   direkt per SMB, ohne dass irgendwo etwas gemountet wird. Namenskollisionen
   bekommen einen Zaehler, nichts wird ueberschrieben.
4. Auf Wunsch wird zusaetzlich gedruckt: alles aus einem Postfach, nur was
   eine Zuordnung trifft (z. B. nur Rechnungen), oder alles, was an eine
   bestimmte Adresse geschickt wurde. Siehe [Drucken](#drucken).
5. Die Mail wird als gelesen markiert (optional in einen anderen IMAP-Ordner
   verschoben) und ihre Message-ID vermerkt, damit nichts doppelt verarbeitet
   wird - auch wenn jemand das Gelesen-Flag zuruecksetzt.
6. Abholordner werden alle 30 Sekunden geleert: fertige Scans werden nach
   denselben Regeln einsortiert (und optional gedruckt).

Anhaenge mit ausfuehrbaren Dateiendungen (`.exe`, `.js`, `.ps1` ...) landen
immer in einem Quarantaene-Ordner - auch wenn sie `Rechnung.exe` heissen - und
werden nie gedruckt. Mehr dazu unter
[Sicherheit](#sicherheit-angriffsflaeche-ueber-mailanhaenge).

## Voraussetzungen

- Ein Proxmox-Host (fuer das Helper-Skript) - oder irgendein Linux-System mit
  Docker und Docker Compose.
- Ein IMAP-Postfach, am besten ein eigenes Konto mit App-Passwort.
- Eine SMB-Freigabe mit einem Benutzer, der in die Zielordner schreiben darf.
  **Gemountet werden muss nichts**, weder auf dem Host noch im Container, und
  es braucht kein `cifs-utils`.
- Ein Browser im selben Netz - die Weboberflaeche laeuft auf Port 8080.
- Optional fuers Drucken: ein Drucker an einem CUPS-Server, den der Container
  erreicht. Der CUPS-Client steckt im Image.
- Internet- bzw. Mirror-Zugriff fuer `apt`, Docker-Images und `pip`. Zugriff
  auf GitHub ist praktisch, aber nicht zwingend (siehe
  [Variante 3](#variante-3-ohne-zugriff-auf-github-bootstrap)).

## Installation

Keine der Varianten fragt nach Mail- oder NAS-Zugangsdaten: die kommen danach
in der Weboberflaeche dazu. Jede Variante endet mit der Adresse der
Oberflaeche und einem **zufaellig erzeugten Startpasswort**.

### Variante 1: Proxmox-Helper-Skript (empfohlen)

Auf der Shell des **Proxmox-Hosts** (Datacenter -> Node -> Shell, nicht in
einer Container-Konsole):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/mail2nas.sh)"
```

Im Menue **"Neu installieren"** waehlen. Das Skript

1. fragt nur die Container-Ressourcen ab (Standard: 1 Kern, 512 MB RAM, 4 GB
   Disk, DHCP auf `vmbr0`, unprivilegiert - oder erweitert mit eigener CTID,
   Bridge, Port),
2. legt eine Debian-12-LXC mit `nesting=1,keyctl=1` an (noetig fuer Docker),
3. installiert darin Docker und mail2nas nach `/opt/mail2nas`,
4. zeigt am Ende **Adresse und Startpasswort** der Weboberflaeche.

Dasselbe Skript aktualisiert spaeter auch - siehe [Updates](#updates).
Ohne Menue: `... mail2nas.sh install` bzw. `... mail2nas.sh update [CTID]`.

### Variante 2: In einer vorhandenen LXC/VM

In einer Debian/Ubuntu-LXC oder -VM als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/install.sh)"
```

Installiert git und Docker (falls noetig), holt den Code nach
`/opt/mail2nas`, schreibt eine `.env` mit Port und Zeitzone, startet und gibt
Adresse und Startpasswort aus. Laeuft dort schon mail2nas, wird stattdessen
aktualisiert - ein erneuter Aufruf ist also gefahrlos.

Optional: `WEB_PORT=9090 TZ=Europe/Vienna bash -c "$(curl ...)"`.

Bei einer selbst angelegten LXC muessen unter *Optionen -> Features*
`nesting` und `keyctl` aktiv sein, sonst startet Docker nicht.

### Variante 3: Ohne Zugriff auf GitHub (Bootstrap)

`scripts/bootstrap.sh` enthaelt das komplette Projekt in einer einzigen Datei.
Auf einem Rechner mit Zugriff herunterladen, auf das Zielsystem bringen
(Copy & Paste in eine SSH-Sitzung genuegt, oder `scp`), dort:

```bash
bash bootstrap.sh /opt/mail2nas
cd /opt/mail2nas
cp .env.example .env
docker compose up -d --build
docker compose exec mail2nas python -m mail2nas.cli password   # Startpasswort
```

Ein Update geht genauso: neue `bootstrap.sh` ausfuehren, dann
`MAIL2NAS_OFFLINE=1 bash /opt/mail2nas/scripts/proxmox/update.sh` - das baut,
migriert und raeumt auf, ohne etwas herunterzuladen.

### Variante 4: Docker Compose von Hand

```bash
git clone https://github.com/Internerd/mail2nas.git /opt/mail2nas
cd /opt/mail2nas
cp .env.example .env        # optional - ohne .env gelten die Defaults
docker compose up -d --build
docker compose logs | grep "generated one"   # oder: python -m mail2nas.cli password
```

Die `.env` enthaelt nur noch Port, Zeitzone und Log-Level, siehe
[Wo die Konfiguration liegt](#wo-die-konfiguration-liegt).

### Ohne Docker (systemd)

Moeglich, aber mit mehr Handarbeit - Docker ist der getestete Weg.

```bash
apt-get install -y python3-venv cups-client
useradd --system --home /var/lib/mail2nas --create-home mail2nas
git clone https://github.com/Internerd/mail2nas.git /opt/mail2nas
python3 -m venv /opt/mail2nas/venv
/opt/mail2nas/venv/bin/pip install -r /opt/mail2nas/requirements.txt

cat > /etc/systemd/system/mail2nas.service <<'EOF'
[Unit]
Description=mail2nas
After=network-online.target
Wants=network-online.target

[Service]
User=mail2nas
WorkingDirectory=/opt/mail2nas
Environment=STATE_DB_PATH=/var/lib/mail2nas/state.db
Environment=WEB_PORT=8080
ExecStart=/opt/mail2nas/venv/bin/python -m mail2nas.main
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now mail2nas
cat /var/lib/mail2nas/initial-password.txt
```

## Erste Einrichtung

Nach dem ersten Aufruf von `http://<ip>:8080/` fuehrt die **Uebersicht** durch
die Einrichtung. Die Reihenfolge:

1. **Anmelden** mit dem Startpasswort und unter **Passwort** ein eigenes
   setzen. Das Startpasswort wird dabei auch vom Server geloescht.
2. **Archiv einrichten** (Konfiguration -> Archiv hinzufuegen): Server,
   Freigabe, Benutzer, Passwort des NAS. **Verbindung testen** schreibt eine
   winzige Testdatei und loescht sie wieder - danach steht fest, dass
   Zugangsdaten und Schreibrechte stimmen.
3. **Postfach anlegen** (Konfiguration -> Postfach hinzufuegen): IMAP-Server,
   Benutzer, Passwort, Ordner. **Anmeldung und Ordner pruefen** meldet sich
   an und zeigt, wie viele ungelesene Mails warten - ohne eine anzufassen.
4. **Zuordnungen anlegen**: Stichwort eintippen, Zielordner aus der Liste der
   Ordner auf dem NAS waehlen (oder einen neuen anlegen). Eine
   `mapping.yaml` aus einer anderen Installation laesst sich importieren.
5. Optional: **Drucker**, **Zustelladressen**, **Abholordner**, und unter
   **Einstellungen** Ordnernamen, Grenzwerte und den Testmodus.

Solange kein Archiv eingerichtet und erfolgreich getestet ist, holt mail2nas
**keine** Mail ab - die Oberflaeche sagt das auf jeder Seite. So kann nichts
an einem Ort landen, an dem es niemand erwartet.

**Zum Ausprobieren** gibt es unter Einstellungen den **Testmodus**: es wird
nichts abgelegt, gedruckt oder als gelesen markiert, nur protokolliert, was
passieren wuerde (`docker compose logs -f`).

## Die Weboberflaeche

```
http://<container-ip>:8080/
```

| Seite | Inhalt |
|---|---|
| **Uebersicht** | Einrichtungsschritte, Zustand des Archivs, je Postfach: verbunden / Fehler / zuletzt ok, Anzahl verarbeiteter Mails, Probleme mit Abholordnern |
| **Zuordnungen** | Stichwort -> Ordner, Reihenfolge mit Pfeilen, je Zeile Postfach, Archiv und Drucken; Export und Import als `mapping.yaml` |
| **Konfiguration** | Postfaecher, Archive, Drucker (inkl. Suche im Netzwerk), Zustelladressen, Abholordner - jeweils mit Test-Knopf |
| **Einstellungen** | Ordner fuer Unsortiertes und Quarantaene, Dateinamen, gesperrte Dateitypen, Abrufintervall, Grenzwerte, Drucken, Testmodus |
| **Passwort** | eigenes Passwort setzen |

Jede Aenderung wirkt sofort - **ein Neustart des Containers ist nie noetig**.
Geaenderte Zugangsdaten eines Postfachs bauen nur dessen Verbindung neu auf;
Einstellungen gelten ab der naechsten Mail.

### Zuordnungen: Stichwoerter, Reihenfolge, Platzhalter

- **Gross-/Kleinschreibung ist egal.** `re`, `RE` und `Re` sind dasselbe.
- **Gesucht wird als Teilstring**, nicht als ganzes Wort: `RE` passt auch auf
  "VORAB-RECHNUNG". Wer das nicht will, nimmt ein laengeres Stichwort.
- **`*` steht fuer beliebig viele Zeichen, `?` fuer genau eines:**

  | Stichwort | passt auf | passt nicht auf |
  |---|---|---|
  | `RE*` | "Ihre RE-4711" | "Angebot" |
  | `RE*2026` | "RE-4711 vom 03.2026" | "RE-4711 vom 03.2025" |
  | `Rechn?ng` | "Rechnung", "Rechnang" | "Rechnuung" |

  Alle anderen Zeichen gelten woertlich - `RE.` ist kein regulaerer Ausdruck.
  Hoechstens 5 `*` pro Stichwort.
- **Die Reihenfolge entscheidet**: die erste passende Zuordnung gewinnt. Mit
  den Pfeilen kommt `Rechnungskorrektur` ueber `RE`.
- **Jeder Anhang einzeln**: zuerst zaehlt sein eigener Dateiname, dann der
  Betreff. Eine Mail mit `Rechnung_4711.pdf` und `Lieferschein_4711.pdf` wird
  so auf `rechnungen/` und `lieferscheine/` aufgeteilt. Anhaenge ohne
  Hinweis im Namen (`scan0001.pdf`) folgen dem Betreff.
- **Je Zuordnung waehlbar**: fuer welches Postfach sie gilt, auf welchem
  Archiv der Ordner liegt (sobald es mehrere gibt) und ob gedruckt wird.

### Sichern und uebertragen

Unter Zuordnungen -> *Sichern und uebertragen*:

- **Als mapping.yaml herunterladen** - eine lesbare Sicherung aller
  Zuordnungen.
- **mapping.yaml importieren** - wahlweise anhaengen (Stichwoerter, die es
  schon gibt, werden uebersprungen) oder ersetzen. Gelesen werden das aktuelle
  Format und das alte (`Stichwort: ordner`). Verweise auf Postfaecher,
  Drucker oder Archive, die es in dieser Installation nicht gibt, werden auf
  den Standard gesetzt. Ein Ordner ausserhalb des Archivs (`../`, `/etc`)
  bricht den Import ab, ohne etwas zu aendern.

```yaml
version: 2
rules:
  - keyword: Rechnungskorrektur   # steht vor "RE" - sonst griffe "RE" zuerst
    folder: korrekturen
  - keyword: "RE*"
    folder: rechnungen
    account: "2"                  # nur fuer das Postfach mit dieser ID
    print: true                   # zusaetzlich drucken
    printer: "1"                  # ID eines Druckers; weglassen = der des Postfachs
    archive: "3"                  # ID eines Archivs; weglassen = Standard-Archiv
```

Beispiel-Datei: [`config/mapping.example.yaml`](config/mapping.example.yaml).

### Mehrere Postfaecher

Beliebig viele IMAP-Postfaecher, je mit eigenem Server, Ordner und Abrufmodus.
Jedes laeuft in einem eigenen Thread, damit ein Postfach im IDLE-Modus die
anderen nicht blockiert. Pausieren (Haken "aktiv" weg) statt loeschen ist
moeglich. Je Postfach einstellbar:

- **Verarbeitete Mails verschieben nach** - sonst nur als gelesen markiert.
- **Zu grosse Mails verschieben nach** - Mails ueber der Maximalgroesse werden
  gar nicht geladen, nur markiert (und ggf. verschoben).
- **Alle Anhaenge drucken**, **Drucker** und **Im Archiv ablegen** - siehe
  [Drucken](#drucken).

Wird ein Postfach geloescht, bleiben seine Zuordnungen stehen und greifen
nicht mehr - die Oberflaeche zeigt sie als "(geloeschtes Postfach)".

### Einstellungen

| Einstellung | Bedeutung | Standard |
|---|---|---|
| Ordner fuer Anhaenge ohne Treffer | im Standard-Archiv | `unsorted` |
| Quarantaene-Ordner | fuer gesperrte Dateitypen | `quarantaene` |
| Dateiname beginnt mit | Datum und Absender / nur Datum / nur Absender / nichts | Datum und Absender |
| Stichwoerter auch im Mailtext suchen | sonst nur Dateiname und Betreff | aus |
| Gesperrte Dateitypen | gehen immer in die Quarantaene; leer = keine Pruefung | `exe, js, ps1, jar, lnk, sh, ...` |
| Abrufintervall | Polling bzw. IDLE-Erneuerung (10 s - 24 h) | 300 s |
| Max. Groesse je Anhang / je Mail | dahinter wird uebersprungen bzw. gar nicht geladen | 25 / 50 MB |
| Max. Anhaenge je Mail | Schutz vor Mails mit tausenden Anhaengen | 20 |
| Abholordner: fertig nach | so lange muss eine Datei unveraendert sein | 20 s |
| Drucken erlaubt | Notschalter fuer alles Drucken | an |
| Druckbare Dateitypen | nur diese gehen an einen Drucker; leer = Standardliste | PDF, PS, Text, Bilder |
| Zeitgrenze je Druckauftrag | danach gilt er als gescheitert | 120 s |
| Testmodus | nichts ablegen, drucken oder markieren - nur protokollieren | aus |

Ungueltige Werte (Buchstaben im Intervall, ein Ordner ausserhalb des Archivs,
Fallback gleich Quarantaene) werden mit einer Meldung abgelehnt; es bleibt
dann alles beim Alten.

### Passwort

Beim allerersten Start erzeugt mail2nas ein zufaelliges Passwort
(`abcd-efgh-...`, ohne verwechselbare Zeichen). Es steht

- in der Ausgabe von Installer und Update,
- im Container-Log (`docker compose logs | grep "generated one"`),
- in `/data/initial-password.txt` im Container (`chmod 600`),
- und per `docker compose exec mail2nas python -m mail2nas.cli password`.

Sobald ein eigenes gesetzt ist, wird diese Datei geloescht. Gespeichert wird
nur ein Hash (scrypt). Beim Aendern werden alle anderen Sitzungen abgemeldet.

**Passwort vergessen?** In der LXC:

```bash
cd /opt/mail2nas && docker compose exec mail2nas python -m mail2nas.cli reset-password
```

Das gibt ein neues Zufallspasswort aus und meldet alle Sitzungen ab.

### Sicherheit der Oberflaeche

Die Oberflaeche gehoert ins eigene LAN und ist entsprechend gebaut:

- Ein Passwort, keine Benutzerverwaltung. Nach 5 Fehlversuchen ist die
  Anmeldung fuer eine Minute gesperrt (pro IP).
- Session-Cookie mit `HttpOnly` und `SameSite=Lax`, CSRF-Token in jedem
  Formular, Sitzungsdauer 12 Stunden.
- Kein JavaScript, keine externen Ressourcen, strikte Content-Security-Policy.
- Gespeicherte Passwoerter (IMAP, SMB) werden nie zurueck ins Formular
  geschrieben; ein leeres Feld heisst "unveraendert".
- Zielordner werden wie beim Ablegen geprueft: `..` und absolute Pfade werden
  abgelehnt.

**Nicht direkt ins Internet stellen.** Es gibt kein TLS und keine
Zwei-Faktor-Anmeldung. Von aussen nur per VPN oder hinter einem Reverse-Proxy
mit HTTPS - dann `WEB_COOKIE_SECURE=true` in der `.env` setzen.

Wer die Oberflaeche bedienen kann, kann Postfaecher und Archive anlegen - das
Passwort ist also so wertvoll wie die Zugangsdaten darin.

`GET /healthz` antwortet ohne Anmeldung mit `ok` (fuer Monitoring und den
Docker-Healthcheck).

## Archive: wohin abgelegt wird

Ein Archiv ist der Ort, an dem Anhaenge landen. Es gibt zwei Arten:

| Art | Angaben | wann |
|---|---|---|
| **SMB-Freigabe** (Standard) | Server, Freigabe, Benutzer, Passwort, optional Domain, Port, Unterordner, Verschluesselung | der Normalfall - es wird nichts gemountet |
| **Gemountetes Verzeichnis** | Pfad, z. B. `/mnt/nas` | wenn das Betriebssystem die Freigabe ohnehin einbindet, oder fuer NFS/ZFS/lokale Platten |

Das **erste aktive** Archiv ist das Standard-Archiv: dorthin geht alles ohne
eigene Angabe, und dort liegen der Fallback- und der Quarantaene-Ordner.
Zuordnungen, Zustelladressen und Abholordner koennen jeweils ein anderes
waehlen - `Vertrag -> vertraege` kann so auf einem anderen NAS landen als
`Rechnung -> rechnungen`.

### Warum nichts gemountet wird

mail2nas spricht SMB **direkt aus der Anwendung** (SMB3, per Default
verschluesselt). Es wird kein Dateisystem eingehaengt - nicht im Container,
nicht in der LXC, nicht auf dem Proxmox-Host.

Grund ist eine harte Kernel-Grenze: CIFS ist nicht als `FS_USERNS_MOUNT`
markiert, `mount(2)` ist dafuer aus einer **unprivilegierten LXC** verboten -
egal ob per `mount.cifs` oder per Dockers cifs-Volume-Treiber (der zusaetzlich
das SMB-Passwort in den Volume-Metadaten ablegt). Frueher wurde deshalb auf
dem Proxmox-Host gemountet; das machte den Mount fuer jeden mit Root-Shell auf
dem Node sichtbar und legte die Zugangsdaten in eine Datei auf dem Host, die
in jedem Host-Backup landete. Mit direktem SMB entfaellt beides:

```
mail2nas (im Container)  --SMB3-->  //nas/freigabe
        keine Mounts, kein cifs-utils, keine Host-Konfiguration
```

Weitere Eigenschaften:

- Faellt die Verbindung weg (NAS-Neustart, abgelaufene Sitzung), wird sie
  automatisch neu aufgebaut.
- Anhaenge werden unter einem temporaeren Namen geschrieben und erst danach
  umbenannt - ein abgebrochener Transfer hinterlaesst nie eine abgeschnittene
  Datei, die wie eine vollstaendige Rechnung aussieht.
- Aeltere NAS-Firmware lehnt SMB3-Verschluesselung manchmal ab - dann den
  Haken "Verbindung verschluesseln" im Archiv entfernen.
- Mit "Unterordner" laesst sich alles auf einen Teil der Freigabe begrenzen.

### Bereitschaft

Beim Start und nach jeder Aenderung am Standard-Archiv macht mail2nas einen
**Schreibtest**. Erst wenn der gelingt, werden Postfaecher und Abholordner
bearbeitet; schlaegt er fehl, steht der Grund in der Uebersicht und es wird
jede Minute erneut probiert. Ein NAS im Standby oder ein falsches Passwort
fuehrt also nie dazu, dass Anhaenge irgendwo landen, wo sie niemand sucht.

Faellt ein Archiv **im Betrieb** aus, schlaegt das Ablegen fehl, die Mail
bleibt ungelesen und wird beim naechsten Durchlauf erneut versucht. Zeigt
etwas auf ein geloeschtes oder pausiertes Archiv, wird ins Standard-Archiv
gelegt und das protokolliert - lieber am falschen Ort als verloren. Das letzte
Archiv laesst sich nicht loeschen.

### Gemountetes Verzeichnis

Soll doch in ein vom Betriebssystem eingebundenes Verzeichnis geschrieben
werden: in der `.env` `NAS_PATH=/pfad/auf/dem/host` setzen und mit
`docker-compose.local.yml` starten (das Update-Skript tut das automatisch,
sobald `NAS_PATH` gesetzt ist). Im Container heisst das Verzeichnis dann
`/mnt/nas` - diesen Pfad als Archiv vom Typ "Gemountetes Verzeichnis"
eintragen.

```
Host   /etc/fstab:  //nas/share  ->  /mnt/mail2nas-<CTID>   (cifs)
            pct -mp0 Bind-Mount  ->  /mnt/nas   (in der LXC, = NAS_PATH)
   docker-compose.local.yml      ->  /mnt/nas   (im Container)
```

In einer unprivilegierten LXC muss der fstab-Eintrag auf dem Host
`uid=101000,gid=101000` setzen (der Container laeuft als uid 1000, Proxmox
verschiebt den User-Namespace um 100000). Ist das Verzeichnis **kein
Mountpoint**, warnt die Uebersicht - genau so sieht ein vergessener Mount aus,
und dann wuerde in die Container-Platte statt aufs NAS geschrieben.

## Drucken

Anhaenge koennen zusaetzlich zur Ablage ausgedruckt werden - oder statt der
Ablage. Alles daran wird in der Weboberflaeche eingestellt.

### Drucker einmal anlegen, ueberall auswaehlen

Unter **Konfiguration -> Drucker** wird jeder Drucker genau einmal
eingetragen:

| Feld | Bedeutung |
|---|---|
| Anzeigename | wie er in den Auswahlfeldern erscheint, z. B. "Buero EG" |
| Warteschlange in CUPS | der Queue-Name, wie ihn `lpstat -p` zeigt |
| CUPS-Server | leer = lokaler `cupsd`, sonst z. B. `cups.lan:631` |
| Kopien | 1-20 |
| Druckoptionen | wie bei `lp -o`, ohne `-o`, durch Leerzeichen getrennt: `media=A4 sides=two-sided-long-edge` |
| Aktiv | pausierte Drucker bleiben gespeichert, es geht nichts an sie raus |

Danach taucht der Drucker ueberall als Auswahlfeld auf - beim Postfach, bei
jeder Zuordnung, Zustelladresse und jedem Abholordner. **Testseite drucken**
prueft die Warteschlange; Fehlermeldungen von CUPS erscheinen direkt auf der
Seite.

### Drucker im Netzwerk finden

**Konfiguration -> Im Netzwerk suchen** findet

- **Warteschlangen eines CUPS-Servers** (`lpstat -v`) - sofort verwendbar:
  "Uebernehmen" fuellt das Formular vor.
- **Geraete, die sich per mDNS/DNS-SD ankuendigen** (AirPrint, "driverless")
  - mit dem passenden `lpadmin`-Befehl, um daraus eine Warteschlange zu machen:

  ```bash
  lpadmin -p Kyocera_M2540 -v ipp://192.168.1.50:631/ipp/print -E -m everywhere
  ```

mDNS braucht Multicast; im Docker-Bridge-Netz kommt davon nichts an (die Seite
sagt das). Dann den CUPS-Server nutzen oder den Container mit
`network_mode: host` starten. Gesucht wird nur auf Knopfdruck.

### Drucken per Mail-Adresse (Zustelladressen)

Der direkteste Weg zum Ausdruck: **eine Mail an eine dafuer eingerichtete
Adresse schicken.** Unter **Konfiguration -> Zustelladressen**:

| Feld | Bedeutung |
|---|---|
| Empfaengeradresse | `drucker@firma.de`, `@firma.de` (ganze Domain) oder `drucker-*@firma.de` |
| Nur von diesem Absender | optional, gleiche Schreibweise. Leer = von jedem |
| Anhaenge drucken | an/aus, dazu der Drucker |
| Anhaenge ablegen | an/aus, dazu optional ein fester Zielordner und ein Archiv |

Typisch: beim Mailanbieter einen **Alias** `drucker-buero@firma.de` anlegen,
der ins ohnehin ueberwachte Postfach zugestellt wird - ein eigenes IMAP-Konto
braucht es nicht. Erkannt wird die Adresse an `Delivered-To`,
`X-Original-To`, `Envelope-To`, `To`, `Cc` und `Resent-To`.

**Sind Empfaenger und Absender gesetzt, muessen beide passen** - der Absender
ist ein Zugriffsschutz ("drucken darf nur, wer aus unserer Domain schreibt").
Die erste passende Zustelladresse gewinnt.

| Zustelladresse | Drucken | Ablegen | Wirkung |
|---|---|---|---|
| `drucker-buero@firma.de`, Absender `@firma.de` | ja, Buero EG | nein | Kollegen mailen etwas hin, es kommt aus dem Drucker |
| `rechnungen@firma.de` | nein | ja, Ordner `rechnungen` | reine Ablage, ohne dass ein Stichwort passen muss |
| `alles@firma.de` | ja | ja | Papier **und** Archiv |

### Wann gedruckt wird - und auf welchem Drucker

Drei Schalter, kombinierbar:

- **Je Zustelladresse** - die spezifischste Aussage; sie entscheidet auch,
  **ob** gedruckt wird.
- **Je Postfach**: "Alle Anhaenge dieses Postfachs drucken".
- **Je Zuordnung**: nur was diese Regel trifft, z. B. nur Rechnungen.

Der Drucker ergibt sich von speziell nach allgemein: Zustelladresse ->
Zuordnung -> Postfach. Ist keiner gesetzt, wird nicht gedruckt (Warnung im
Log). Beispiel:

| Postfach | Einstellung | Ergebnis |
|---|---|---|
| A | "alle Anhaenge drucken" auf Drucker A, "im Archiv ablegen" aus | alles kommt aus Drucker A, nichts aufs NAS |
| B | Zuordnung `Rechnung` mit Drucker B | alles wird abgelegt, Rechnungen zusaetzlich auf Drucker B gedruckt |

### Nur drucken - ohne dass etwas verloren geht

Ist "Anhaenge im Archiv ablegen" aus, wird nur gedruckt. Damit daraus nie ein
stiller Verlust wird:

- **Kommt nichts aus dem Drucker** - kein Drucker gewaehlt, CUPS nicht
  erreichbar, ein Format, das nicht gedruckt werden kann - wird der Anhang
  **doch abgelegt** und das im Log gemeldet. Die Mail wird ja gleich als
  gelesen markiert; das waere die letzte Gelegenheit.
- Anhaenge mit **gesperrter Dateiendung** landen immer in der Quarantaene.

### Was gedruckt wird - und was nicht

- Gedruckt wird **nach** der Ablage. Das Archiv ist das Original, Papier die
  Kopie: ein Drucker ohne Papier darf nie der Grund sein, dass etwas nicht
  gespeichert wurde. Ein gescheiterter Druck wird gemeldet, die Mail gilt
  trotzdem als verarbeitet - sonst laege bei jedem Versuch eine weitere Kopie
  im Archiv.
- **Quarantaene wird nie gedruckt.**
- Nur Formate, die CUPS selbst versteht (Einstellungen -> Druckbare
  Dateitypen). Ein `.docx` ohne Konverter kaeme als Zeichensalat heraus.

### Voraussetzung: CUPS

Gedruckt wird ueber `lp` (Paket `cups-client` im Image). Ein Druckerdienst
laeuft im Container **nicht** - der Drucker muss an einem CUPS-Server haengen,
der beim Drucker eingetragen wird, oder an einem `cupsd` auf dem Docker-Host.

## Abholordner (Scan-to-Folder)

Viele Kopierer mailen ihre Scans nicht, sondern legen sie per SMB in einen
Ordner. Unter **Konfiguration -> Abholordner** wird so ein Ordner eingetragen,
und mail2nas raeumt ihn ab - mit denselben Zuordnungen, derselben Quarantaene,
derselben Benennung wie bei Mailanhaengen.

| Feld | Bedeutung |
|---|---|
| Abholordner | Ordner, in den das Geraet schreibt, z. B. `scans/kopierer-flur` |
| Zielordner | wohin die Dokumente sollen. Leer = nach Stichwoertern |
| Archiv / Zielarchiv | auf welchem NAS Quelle und Ziel liegen |
| Drucken | zusaetzlich auf einem Drucker ausgeben |

- **Eine Datei wird erst angefasst, wenn sie fertig ist** - wenn sie eine
  einstellbare Zeit (Standard 20 s) unveraendert war.
- **Der Ordner ist ein Postausgang**: Abgeholtes wird *verschoben*, sonst kaeme
  es bei jedem Durchlauf erneut. Dafuer braucht mail2nas dort Loeschrechte.
- Fehlt der Ordner, wird er **angelegt** - das Geraet braucht ihn ja.
- **Unterordner werden mitgelesen**. Versteckte, halbfertige (`.tmp`, `.part`,
  `.crdownload`) und leere Dateien bleiben liegen.
- Ohne Zielordner greifen nur Zuordnungen fuer "alle Postfaecher".
- Ein Zielordner *im* Abholordner wird abgelehnt - das waere eine
  Endlosschleife.
- Geprueft wird alle 30 Sekunden.

## Wo die Konfiguration liegt

| Was | Wo |
|---|---|
| Postfaecher, Archive, Zuordnungen, Drucker, Zustelladressen, Abholordner, Einstellungen, Passwort-Hash, verarbeitete Message-IDs | SQLite-Datenbank `/data/state.db` im Docker-Volume `state` (`chmod 600`) |
| Port, Zeitzone, Log-Level | `/opt/mail2nas/.env` |
| Startpasswort (bis es geaendert wird) | `/data/initial-password.txt` im Volume |

**Nichts davon liegt auf dem NAS.** Die Datenbank enthaelt die IMAP- und
SMB-Passwoerter im Klartext (sie muessen ja zum Anmelden verwendbar sein) und
gehoert deshalb nicht auf eine Freigabe, die viele lesen koennen.

Die komplette `.env`:

| Variable | Bedeutung | Standard |
|---|---|---|
| `WEB_PORT` | Port der Weboberflaeche (Host und Container) | `8080` |
| `WEB_HOST` | Adresse, auf der sie im Container lauscht | `0.0.0.0` |
| `WEB_COOKIE_SECURE` | Session-Cookie nur ueber HTTPS (hinter einem TLS-Proxy auf `true`) | `false` |
| `TZ` | Zeitzone fuer Dateinamen-Datum und Log | `Europe/Berlin` |
| `LOG_LEVEL` | `DEBUG`, `INFO`, `WARNING` | `INFO` |
| `WEB_PASSWORD` | optionales Startpasswort (sonst wird eins erzeugt); nur bis zur ersten Aenderung relevant | leer |
| `NAS_PATH` | nur fuer ein gemountetes Verzeichnis: Host-Pfad, der als `/mnt/nas` in den Container kommt | leer |
| `STATE_DB_PATH` | Pfad der Datenbank (setzt `docker-compose.yml`) | `/data/state.db` |
| `LP_BINARY` / `LPSTAT_BINARY` | nur falls die CUPS-Werkzeuge woanders liegen | `lp` / `lpstat` |

Aeltere `.env`-Dateien mit `IMAP_*`, `SMB_*`, `MAPPING_PATH`,
`FALLBACK_FOLDER` usw. funktionieren weiter: ihre Werte werden beim ersten
Start **einmalig** in die Datenbank uebernommen und danach ignoriert. Das
Update-Skript raeumt sie anschliessend aus der `.env`.

### Sichern

Die Datenbank ist die ganze Konfiguration. Sichern im laufenden Betrieb
(konsistent, per SQLite-Backup-API):

```bash
cd /opt/mail2nas
docker compose exec mail2nas python -c "import sqlite3; sqlite3.connect('/data/state.db').backup(sqlite3.connect('/data/state.db.bak'))"
docker compose cp mail2nas:/data/state.db.bak ./state-$(date +%F).db
chmod 600 ./state-*.db
```

Die Sicherung enthaelt die Passwoerter - entsprechend ablegen. Die
Zuordnungen allein gibt es zusaetzlich als lesbaren Export in der Oberflaeche.
Ein Proxmox-Backup der LXC enthaelt das Volume ohnehin.

## Updates

### Kurzfassung

| Wo | Befehl |
|---|---|
| Proxmox-Host | Helper-Skript starten, **"Bestehende Installation aktualisieren"**: `bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/mail2nas.sh)"` |
| in der LXC | `mail2nas-update` |
| in der LXC, falls der Befehl noch fehlt (aeltere Installation) | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/Internerd/mail2nas/main/scripts/proxmox/update.sh)"` |
| ohne GitHub-Zugriff | neue `bootstrap.sh` ausfuehren, dann `MAIL2NAS_OFFLINE=1 bash /opt/mail2nas/scripts/proxmox/update.sh` |

Das Update fragt nichts und braucht keine Zugangsdaten.

### Was beim Update passiert

1. **Sicherung**: `.env` -> `.env.bak.<Zeitstempel>` (`chmod 600`), Datenbank ->
   `/data/state.db.bak-<Zeitstempel>` im Volume.
2. **Code holen**. Eine Installation ohne git (per bootstrap.sh oder scp) wird
   dabei in einen git-Checkout umgewandelt. Lokale Aenderungen am Code werden
   verworfen, `.env` und Sicherungen bleiben.
3. **Neu bauen** (`--pull`, damit auch Basis-Image und Abhaengigkeiten
   Sicherheitsupdates bekommen) und starten.
4. **Uebernahme abwarten**: beim ersten Start einer neuen Version uebernimmt
   mail2nas, was bisher in der `.env` stand - Postfach, Archiv, erster Drucker,
   Ordner, Grenzwerte, Quarantaene-Liste, Testmodus, Startpasswort - sowie die
   **`mapping.yaml` vom NAS**. Die Datei heisst danach `mapping.yaml.migriert`,
   damit niemand weiter eine Datei bearbeitet, die nichts mehr bewirkt. Die
   Oberflaeche meldet unter Zuordnungen, wie viele Regeln uebernommen wurden.
   Postfaecher werden erst abgeholt, **nachdem** die Regeln uebernommen sind -
   sonst landeten die ersten Mails nach dem Update im Fallback-Ordner.
5. **`.env` aufraeumen**: sobald die Uebernahme bestaetigt ist, bleiben nur
   Port, Zeitzone, Log-Level (und `NAS_PATH`, falls gemountet wird). Die
   Passwoerter stehen dann nur noch in der Datenbank - und in der Sicherung aus
   Schritt 1, die nach einer Kontrolle geloescht werden sollte.
   (`MAIL2NAS_KEEP_ENV=1` laesst die `.env`, wie sie ist.)
6. **Aufraeumen**: alte Images, und das Docker-cifs-Volume der ersten
   Versionen.

Ein erneuter Aufruf ist jederzeit gefahrlos.

### Von welchen Versionen

| Generation | erkennbar an | was das Update tut |
|---|---|---|
| **Docker-cifs-Volume** (erste Versionen) | `SMB_HOST`/`SMB_SHARE`/`SMB_USER`/`SMB_PASSWORD` in der `.env`, kein `STORAGE_BACKEND` | Archiv wird als **direktes SMB** uebernommen; das alte Volume `mail2nas_nas` wird entfernt |
| **Share auf dem Proxmox-Host gemountet** | `NAS_PATH` bzw. kein SMB in der `.env`, Bind-Mount `/mnt/nas` | Archiv als gemountetes Verzeichnis `/mnt/nas`; der Bind-Mount bleibt aktiv. Das Helper-Skript bietet die **Umstellung auf direktes SMB** an (siehe unten) |
| **Direktes SMB** (`STORAGE_BACKEND=smb`) | | Archiv als SMB uebernommen, kein Mount |
| **mit Weboberflaeche und Archiven** | Postfaecher/Archive schon in der Datenbank | nur die restlichen `.env`-Werte und die `mapping.yaml` werden uebernommen |
| **Offline-Installation** (bootstrap.sh, scp) | kein `.git` | wird in einen git-Checkout umgewandelt, danach wie oben |

### Host-Mount auf direktes SMB umstellen

Installationen aus der Host-Mount-Zeit haben die SMB-Zugangsdaten in
`/etc/mail2nas-smb-credentials-<CTID>` auf dem Proxmox-Host. Das Helper-Skript
findet die Datei beim Update und fragt, ob umgestellt werden soll. Dann

1. wird mit diesen Zugangsdaten ein **Schreibtest** gemacht - schlaegt er fehl,
   bleibt alles, wie es ist,
2. schreibt mail2nas ab sofort direkt per SMB,
3. auf Wunsch (zweite Nachfrage) werden der Bind-Mount aus der LXC entfernt
   (Container-Neustart), der fstab-Eintrag geloescht (Sicherung
   `/etc/fstab.bak.*`), der Mount abgebaut und die Zugangsdatei geloescht.

Danach liegen auf dem Host weder Mount noch Passwort.

### Zurueckrollen

```bash
cd /opt/mail2nas
git log --oneline -5                         # frueheren Stand suchen
git reset --hard <commit>
cp .env.bak.<Zeitstempel> .env               # alte .env zurueck
docker compose exec mail2nas python -c "import shutil; shutil.copy('/data/state.db.bak-<Zeitstempel>', '/data/state.db')"
docker compose up -d --build
```

Wer auf eine Version vor der Datenbank-Konfiguration zurueckgeht, muss
ausserdem `mapping.yaml.migriert` auf dem NAS wieder in `mapping.yaml`
umbenennen.

## Kommandozeile

Fuer die wenigen Dinge, die ohne Browser gehen muessen - in der LXC:

```bash
cd /opt/mail2nas
docker compose exec mail2nas python -m mail2nas.cli status          # Uebernahme, Anzahl Postfaecher/Archive/Regeln
docker compose exec mail2nas python -m mail2nas.cli password        # Startpasswort anzeigen
docker compose exec mail2nas python -m mail2nas.cli reset-password  # neues Zufallspasswort
```

`archive-to-smb` (liest Zugangsdaten als JSON von stdin) nutzt das
Helper-Skript fuer die Umstellung vom Host-Mount.

## Sicherheit: Angriffsflaeche ueber Mail/Anhaenge

Mails und Anhaenge kommen von aussen und sind nicht vertrauenswuerdig:

- **Keine Pfad-Traversal ueber Dateinamen**: Anhang-Namen werden normalisiert
  und auf ein sicheres Zeichenset reduziert (`sanitize_filename`) - auch
  Unicode-Tricks wie Fullwidth-Slashes oder Right-to-Left-Override brechen
  nicht aus dem Zielordner aus.
- **Keine Pfad-Traversal ueber Zielordner**: Ordner aus Zuordnungen, Adressen
  und Importen werden beim Speichern und nochmals beim Ablegen geprueft;
  absolute Pfade und `..` werden abgewiesen, ein abgewiesenes Ziel landet im
  Fallback-Ordner statt ausserhalb des Archivs.
- **Atomares Schreiben**: temporaerer Name, dann Umbenennen - nie eine
  abgeschnittene Datei unter einem vollstaendig aussehenden Namen.
- **Groessenlimits**: die Mailgroesse wird per `RFC822.SIZE` geprueft,
  *bevor* der Inhalt geladen wird; Anhaenge und ihre Anzahl sind zusaetzlich
  begrenzt.
- **Quarantaene fuer ausfuehrbare Dateitypen**: `.exe`, `.js`, `.ps1`,
  `.jar`, `.lnk`, `.sh` usw. gehen **immer** in den Quarantaene-Ordner, auch
  wenn ein Stichwort passt - "Rechnung.exe" landet nie im Rechnungsordner. Die
  Datei bleibt zur Pruefung erhalten - **niemals von dort oeffnen**, ohne den
  Inhalt zu kennen.
- **Nichts Gesperrtes geht an einen Drucker**; nur bekannte Formate werden
  gespoolt. Die Druckdatei liegt waehrend der Uebergabe mit `0600` im
  Temp-Verzeichnis und wird sofort geloescht.
- **Kein Entpacken, kein Parsen, kein Ausfuehren**: Anhaenge werden als
  Rohbytes gespeichert. Zip-Bombs, Makros und Parser-Exploits spielen damit
  hier keine Rolle - die Verantwortung liegt bei dem, der die Datei spaeter
  oeffnet.
- **Begrenzter Aufwand beim Matching**: Platzhalter-Stichwoerter und der
  durchsuchte Text sind in der Laenge begrenzt, die Empfaengerliste einer Mail
  auch - eine praeparierte Mail kann einen Worker nicht lahmlegen.
- **TLS mit Zertifikatspruefung** fuer IMAP (Standard-`ssl`-Kontext), SMB3
  mit Verschluesselung; IMAP-Befehle haben ein Zeitlimit, damit ein haengender
  Server den Worker nicht fuer immer blockiert.
- **Idempotenz**: verarbeitete Message-IDs werden vermerkt, eine kaputte Mail
  wird nicht in jeder Runde erneut komplett verarbeitet.

Das ersetzt keinen Virenscanner. Wer Mail aus dem offenen Internet verarbeitet,
sollte vor dem Postfach filtern (beim Provider oder per ClamAV).

## Betrieb & Troubleshooting

Der erste Blick gehoert immer der **Uebersicht** in der Weboberflaeche: dort
steht der Zustand des Archivs und je Postfach der letzte Fehler im Klartext.
Details liefert das Log:

```bash
cd /opt/mail2nas && docker compose logs -f
```

- **"Noch kein Archiv eingerichtet" / "nicht bereit"**: ohne funktionierendes
  Archiv wird bewusst nichts abgeholt. Der Grund steht in der Uebersicht:
  - `STATUS_LOGON_FAILURE` -> Benutzer/Passwort/Domain des Archivs pruefen.
  - `STATUS_BAD_NETWORK_NAME` oder `No such file` direkt unter der Freigabe ->
    Freigabename (oder Unterordner) stimmt nicht, Gross-/Kleinschreibung
    beachten.
  - `STATUS_ACCESS_DENIED` -> der Benutzer darf dort nicht schreiben.
  - Timeout / `Connection refused` -> Server, Port 445, Firewall.
  - Meldungen zu Verschluesselung/Dialekt -> Haken "Verbindung verschluesseln"
    entfernen (aeltere NAS-Firmware).
  - "kein Mountpoint" (gemountetes Verzeichnis) -> der Mount fehlt, siehe
    [Gemountetes Verzeichnis](#gemountetes-verzeichnis).
- **Ein Postfach zeigt "Fehler"**: der Text daneben kommt vom IMAP-Server.
  "Anmeldung und Ordner pruefen" auf der Postfach-Seite testet dieselben Daten
  gezielt. Haeufig: App-Passwort noetig, falscher Ordnername, Port/TLS.
- **Mail landet im Fallback-Ordner**: Reihenfolge der Zuordnungen pruefen
  (eine weiter oben greift zuerst), ob die Zuordnung auf ein anderes Postfach
  beschraenkt ist, und ob das Stichwort wirklich im Dateinamen oder Betreff
  steht - sonst unter Einstellungen den Mailtext mit durchsuchen lassen.
- **Nach dem Update keine Zuordnungen**: unter Zuordnungen steht, ob und woher
  sie uebernommen wurden. War die alte `mapping.yaml` fehlerhaft, liegt sie
  unveraendert auf dem NAS - korrigieren und importieren.
- **Es passiert gar nichts**: im Testmodus? (Hinweis in der Uebersicht.)
  Liegen im ueberwachten Ordner ueberhaupt *ungelesene* Mails?
- **Weboberflaeche nicht erreichbar**: `docker compose ps` (laeuft der
  Container, ist er "healthy"?), `curl http://localhost:8080/healthz` in der
  LXC. `Web UI cannot listen on ...` im Log heisst: Port belegt - `WEB_PORT`
  in der `.env` aendern.
- **Passwort vergessen**: `docker compose exec mail2nas python -m mail2nas.cli reset-password`.
- **"Zu viele Fehlversuche"**: die Sperre laeuft nach einer Minute ab.
- **Es wird nicht gedruckt**: zuerst "Testseite drucken" beim Drucker - die
  Fehlermeldung kommt direkt von CUPS. Im Log:
  - `lp nicht gefunden` -> Image zu alt, `mail2nas-update`.
  - `no usable printer is configured` -> Drucken ist gewuenscht, aber kein
    aktiver Drucker gewaehlt.
  - `is not in PRINTABLE_EXTENSIONS` -> Format bewusst nicht gedruckt
    (Einstellungen -> Druckbare Dateitypen).
  - gar nichts -> "Drucken erlaubt" unter Einstellungen aus?
- **An eine Adresse gemailt, nichts gedruckt**: steht im Log
  `is addressed to ...`? Wenn nicht, wurde die Adresse nicht erkannt - die
  Kopfzeilen der Mail ansehen ("Original anzeigen") und die Adresse genau so
  eintragen, oder mit `@firma.de` / `drucker-*@firma.de` arbeiten. Ist ein
  Absender eingetragen, muss auch der passen.
- **Abholordner bleibt voll**: Datei noch zu jung (Einstellungen -> fertig
  nach)? Endet sie auf `.tmp`/`.part` oder beginnt mit einem Punkt? Darf
  mail2nas dort loeschen? Ohne Loeschrecht wird bewusst nichts abgeholt.

## Bekannte Grenzen

- **Nur ungelesene Mails** werden verarbeitet. Wer eine Mail im Mailprogramm
  oeffnet, bevor mail2nas sie gesehen hat, nimmt sie ihm weg - daher ein
  eigenes Postfach bzw. ein eigener Ordner.
- Scheitert das Ablegen **mitten** in einer Mail mit mehreren Anhaengen (NAS
  faellt aus), wird die ganze Mail spaeter erneut verarbeitet; die schon
  abgelegten Anhaenge liegen dann doppelt (mit Zaehler im Namen) vor.
- Die Liste verarbeiteter Message-IDs waechst mit jeder Mail (wenige Bytes pro
  Mail - auch nach Jahren unkritisch).
- Ein Passwort fuer alle, keine Benutzerrollen, kein TLS von Haus aus.

## Tests und Entwicklung

```bash
python3 -m venv venv
venv/bin/pip install -r requirements-dev.txt
venv/bin/pytest
```

Die Suite deckt u. a. die Schutzmassnahmen ab (Traversal ueber Zielordner und
Importe, Quarantaene, Groessenlimits), die Uebernahme aller alten
`.env`-Generationen und der `mapping.yaml`, die Bereitschaftspruefung, die
Weboberflaeche und das Update-Skript (gegen nachgebaute Installationen aller
Generationen, mit einem stellvertretenden `docker`).

`scripts/bootstrap.sh` wird generiert, nicht von Hand gepflegt:

```bash
python3 scripts/regenerate-bootstrap.py          # neu erzeugen
python3 scripts/regenerate-bootstrap.py --check  # nur pruefen (fuer CI)
```

Aufbau des Codes:

| Modul | Aufgabe |
|---|---|
| `main.py` | Start, Supervisor (Bereitschaft, Worker je Postfach, Abholordner) |
| `web.py` | Weboberflaeche |
| `options.py` | allgemeine Einstellungen in der Datenbank |
| `legacy.py`, `migrate.py` | Uebernahme aelterer Installationen |
| `archiver.py`, `scanning.py` | Mail bzw. Abholordner verarbeiten |
| `mapping.py` | Zuordnungen: Speicherung, Matching, Import/Export |
| `accounts.py`, `archives.py`, `printers.py`, `addresses.py`, `pickups.py` | die jeweiligen Tabellen |
| `storage.py` | SMB und lokales Verzeichnis |
| `printing.py`, `discovery.py` | Drucken, Drucker finden |
| `cli.py` | Befehle fuer die Skripte |

## Sicherheitshinweise

- **Die Datenbank enthaelt IMAP- und SMB-Passwoerter im Klartext** - sie
  muessen zum Anmelden verwendbar sein. mail2nas haelt sie auf `chmod 600` im
  Docker-Volume `state`. Backups des Volumes (und Proxmox-Backups der LXC)
  enthalten die Passwoerter - entsprechend ablegen.
- Die `.env` enthaelt nach dem Update keine Passwoerter mehr. Die Sicherungen
  `.env.bak.*`, die das Update anlegt, schon - nach einer Kontrolle loeschen.
- Dediziertes IMAP-Konto mit App-Passwort, dedizierter SMB-Benutzer mit
  Schreibrechten nur auf die noetigen Ordner.
- Weboberflaeche nur im LAN, Startpasswort gleich ersetzen.
- Auf dem Proxmox-Host liegen weder Mount noch Zugangsdaten (ausser bei einer
  noch nicht umgestellten Host-Mount-Installation).
- Sicherheitsluecken bitte nicht als oeffentliches Issue melden, siehe
  [SECURITY.md](SECURITY.md).

## Datenschutz (DSGVO)

mail2nas verarbeitet E-Mails und Anhaenge, die typischerweise
personenbezogene Daten enthalten (Namen, Adressen, Bankverbindungen in
Rechnungen/Lieferscheinen usw.). Wer das Tool einsetzt, ist im Sinne der
DSGVO fuer diese Verarbeitung verantwortlich. Ein paar Punkte:

- **Datensparsamkeit im Log**: geloggt werden Betreff, Absenderadresse,
  Anhang-Dateinamen und Zielpfade, nicht der Mailinhalt. Betreffzeilen koennen
  trotzdem personenbezogene Daten enthalten - Logs entsprechend absichern.
- **Zugriffsbeschraenkung**: nur Personen mit begruendetem Zugriff sollten
  Rechte auf die Freigabe, die Weboberflaeche und die LXC haben.
- **Verschluesselung**: IMAP per TLS, SMB3 mit Verschluesselung (Standard).
- **Auftragsverarbeitung**: wird mail2nas fuer Mails Dritter betrieben, kann
  eine Verarbeitung im Sinne von Art. 28 DSGVO vorliegen - dann einen
  Auftragsverarbeitungsvertrag pruefen.
- Dieses Projekt ist Software, keine Rechtsberatung.

## Rechnungsarchivierung / GoBD-Hinweis

mail2nas legt Anhaenge unveraendert (Rohbytes) mit Datums-/Absender-Praefix
auf dem NAS ab. Das hilft beim Sortieren, **ersetzt aber keine GoBD-konforme
("revisionssichere") Archivierung**. Fuer steuerlich relevante Belege
verlangen die GoBD zusaetzlich:

- **Unveraenderbarkeit/Nachvollziehbarkeit** (z. B. WORM-Storage, Versionierung
  mit Aenderungsprotokoll oder ein Dokumentenmanagementsystem) - ein normaler,
  beschreibbarer SMB-Ordner erfuellt das alleine nicht.
- **Vollstaendigkeit**: mail2nas erfasst nur, was per Mail oder Abholordner
  ankommt.
- **Aufbewahrungsfristen** von 8 bzw. 10 Jahren (§ 147 AO), inkl. Backup.

mail2nas ist ein **Zubringer/Sortier-Werkzeug**. Im Zweifel die
Steuerberatung fragen.

## Haftungsausschluss

mail2nas ist ein privates Open-Source-Projekt, keine kommerzielle Software
und keine Rechts-, Steuer- oder Sicherheitsberatung. Es wird "wie besehen"
("as is"), ohne jegliche Gewaehrleistung bereitgestellt - siehe die
Haftungsausschluss-Klausel in der [LICENSE](LICENSE) (MIT). Ergaenzend:

- **Keine Garantie fuer Vollstaendigkeit oder Korrektheit der Ablage.**
  Fehlklassifizierung, ein verpasster Anhang (nicht erkanntes Format, Netz-
  oder IMAP-Fehler, falsche Zuordnung) oder ein Ausfall koennen nicht
  ausgeschlossen werden. Wer sich auf die vollstaendige, fristgerechte
  Archivierung geschaeftskritischer Dokumente verlassen muss, sollte
  zusaetzliche Kontrollen vorsehen (Stichproben, Monitoring, Backups des
  Postfachs).
- **Keine Haftung fuer Datenverlust oder -beschaedigung** auf dem NAS, im
  Postfach oder in der Datenbank, gleich aus welcher Ursache.
- **Keine Haftung fuer Sicherheitsvorfaelle** trotz der beschriebenen
  Massnahmen. Sicherheitsupdates (Basis-Image, Abhaengigkeiten, Betriebssystem
  der LXC) liegen in der Verantwortung der betreibenden Person -
  `mail2nas-update` holt die ersten beiden.
- **Die Skripte** (`scripts/proxmox/*.sh`, `scripts/bootstrap.sh`) greifen in
  die Zielumgebung ein (legen Container an, installieren Pakete, aendern bei
  der Umstellung vom Host-Mount `/etc/fstab`). Vor produktivem Einsatz
  empfiehlt sich ein Testlauf.
- Nutzung auf eigenes Risiko. Bei rechtlichen oder steuerlichen
  Unsicherheiten fachkundigen Rat einholen - siehe
  [Datenschutz](#datenschutz-dsgvo) und [GoBD](#rechnungsarchivierung--gobd-hinweis).

## Lizenz

MIT-Lizenz, siehe [LICENSE](LICENSE). Nutzung auf eigene Verantwortung, ohne
Gewaehrleistung - siehe insbesondere den
[Haftungsausschluss](#haftungsausschluss).
