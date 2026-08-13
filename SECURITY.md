# Security Policy

mail2nas verarbeitet unaufgefordert eingehende Mails/Anhaenge (siehe
[README: Sicherheit](README.md#sicherheit-angriffsflaeche-ueber-mailanhaenge))
und Zugangsdaten fuer IMAP- und SMB-Systeme. Meldungen zu Sicherheitsluecken
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
  auszufuehren, oder die in `BLOCKED_EXTENSIONS`/`QUARANTINE_FOLDER`
  implementierte Quarantaene zu umgehen.
- Denial-of-Service ueber eine einzelne Mail/Verbindung (z. B. Umgehen der
  `MAX_MESSAGE_SIZE_MB`/`MAX_ATTACHMENT_SIZE_MB`/`MAX_ATTACHMENTS_PER_MESSAGE`-
  Limits, Speicher-Erschoepfung).
- Offenlegung von IMAP-/SMB-Zugangsdaten (z. B. in Logs, Fehlermeldungen,
  oder durch unsichere Dateirechte, die die Installer-Skripte setzen).
- Unsichere Defaults in `docker-compose.yml`, `Dockerfile` oder den
  Installations-/Bootstrap-Skripten (`scripts/`).

**Nicht** im Fokus: Fehlverhalten durch bewusst falsch konfigurierte
Umgebungen (z. B. absichtlich deaktivierte TLS-Verifikation, offen
freigegebene SMB-Shares) - das ist eine Konfigurationsfrage, keine
Schwachstelle im Code.

## Reaktionszeit

Dies ist ein von einer Einzelperson gepflegtes Projekt ohne garantierte SLA.
Ich bemuehe mich, innerhalb weniger Tage zu antworten und einen Fix zeitnah
bereitzustellen; bei kritischen Luecken (z. B. Remote Code Execution, Pfad-
Traversal mit Schreibzugriff ausserhalb des Zielordners) hat das Prioritaet.
