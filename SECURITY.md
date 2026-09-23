# Security Policy

mail2nas verarbeitet unaufgefordert eingehende Mails/Anhaenge (siehe
[README: Sicherheit](README.md#sicherheit-angriffsflaeche-ueber-mailanhaenge))
und Zugangsdaten fuer IMAP- und SMB-Systeme. Diese Zugangsdaten und die
gesamte Konfiguration liegen in der SQLite-Datenbank im Docker-Volume `state`
(`/data/state.db` im Container) und werden ausschliesslich ueber die
passwortgeschuetzte Weboberflaeche gepflegt; dieselben Daten stecken in den
Sicherungsdateien. Meldungen zu Sicherheitsluecken
sind daher ausdruecklich willkommen.

## Unterstuetzte Version

Es gibt aktuell nur einen Entwicklungsstand (Branch `main`) - Sicherheitsfixes
werden dort eingespielt. Es existieren keine separat gepflegten
Release-Branches.

## Eine Sicherheitsluecke melden

**Bitte keine oeffentlichen GitHub-Issues fuer Sicherheitsluecken erstellen.**

Bevorzugter Weg: ueber den Tab **"Security" -> "Report a vulnerability"**
dieses Repositories (GitHub Private Vulnerability Reporting). Das erstellt
einen privaten Meldekanal, der nur fuer die Maintainer sichtbar ist.

Bitte in der Meldung nach Moeglichkeit angeben:

- Betroffene Komponente/Datei (z. B. `mail2nas/archiver.py`,
  `scripts/proxmox/install.sh`, Docker-/Compose-Setup, ...)
- Reproduktionsschritte bzw. ein minimales Beispiel (z. B. eine praeparierte
  Test-Mail/Anhang-Struktur, falls relevant)
- Erwartetes vs. tatsaechliches Verhalten und potenzielle Auswirkungen
- Betroffene Version/Commit

## Was als Sicherheitsluecke gilt

Insbesondere relevant fuer dieses Projekt:

- Wege, ueber eine praeparierte Mail oder einen Anhang aus dem konfigurierten
  Zielordner auszubrechen (Pfad-Traversal), beliebigen Code auf dem Host
  auszufuehren, oder die Quarantaene fuer gesperrte Dateitypen
  (Einstellungen "Gesperrte Dateiendungen"/"Quarantaene-Ordner") zu umgehen -
  etwa so, dass ein gesperrter Anhang doch gedruckt wird.
- Denial-of-Service ueber eine einzelne Mail/Verbindung (z. B. Umgehen der
  Groessen- und Anzahl-Limits aus den Einstellungen - Groesse je Mail, je
  Anhang, Anhaenge je Mail -, Speicher-Erschoepfung).
- Offenlegung von IMAP-/SMB-Zugangsdaten (z. B. in Logs, Fehlermeldungen,
  in der Weboberflaeche oder einem Export, oder durch unsichere Dateirechte
  auf Datenbank, `.env` oder `/data/initial-password.txt`).
- Umgehen der Anmeldung, der CSRF-Pruefung oder der Anmeldesperre der
  Weboberflaeche.
- Wege, ueber eine praeparierte Sicherungsdatei (Wiederherstellen) mehr zu
  erreichen als das Ersetzen der Konfiguration - etwa Dateien ausserhalb der
  Datenbank zu schreiben.
- Offenlegung der SMTP-Zugangsdaten der Benachrichtigungen oder Einschleusen
  fremder Kopfzeilen/Empfaenger in Benachrichtigungsmails.
- Unsichere Defaults in `docker-compose.yml`, `Dockerfile` oder den
  Installations-, Update- und Bootstrap-Skripten (`scripts/`).

**Nicht** im Fokus: Fehlverhalten durch bewusst falsch konfigurierte
Umgebungen (z. B. absichtlich deaktivierte TLS-Verifikation, offen
freigegebene SMB-Shares) - das ist eine Konfigurationsfrage, keine
Schwachstelle im Code.

## Reaktionszeit

Dies ist ein von einer Einzelperson gepflegtes Projekt ohne garantierte SLA.
Ich bemuehe mich, innerhalb weniger Tage zu antworten und einen Fix zeitnah
bereitzustellen; bei kritischen Luecken (z. B. Remote Code Execution, Pfad-
Traversal mit Schreibzugriff ausserhalb des Zielordners) hat das Prioritaet.
