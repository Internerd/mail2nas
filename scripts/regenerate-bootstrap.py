#!/usr/bin/env python3
"""Regenerate scripts/bootstrap.sh from the real project files.

bootstrap.sh embeds a copy of every file so the project can be recreated on a
host without git. Keeping those copies in sync by hand is exactly the kind of
thing that silently rots, so generate the script instead:

    python3 scripts/regenerate-bootstrap.py

Run this after changing any embedded file; `--check` verifies it is current
without writing (useful in CI).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DELIMITER = "MAIL2NAS_EOF"

DIRECTORIES = ("mail2nas", "config", "tests", "scripts/proxmox")

# Empty marker files - written with `touch` rather than an empty heredoc.
TOUCH_FILES = ("mail2nas/__init__.py", "tests/__init__.py")

EMBEDDED_FILES = (
    "requirements.txt",
    "requirements-dev.txt",
    ".env.example",
    ".dockerignore",
    "Dockerfile",
    "docker-compose.yml",
    "docker-compose.local.yml",
    "config/mapping.example.yaml",
    "scripts/proxmox/update.sh",
    "mail2nas/config.py",
    "mail2nas/options.py",
    "mail2nas/legacy.py",
    "mail2nas/migrate.py",
    "mail2nas/cli.py",
    "mail2nas/accounts.py",
    "mail2nas/addresses.py",
    "mail2nas/archives.py",
    "mail2nas/pickups.py",
    "mail2nas/printers.py",
    "mail2nas/printing.py",
    "mail2nas/discovery.py",
    "mail2nas/runtime.py",
    "mail2nas/storage.py",
    "mail2nas/mapping.py",
    "mail2nas/filenames.py",
    "mail2nas/state.py",
    "mail2nas/journal.py",
    "mail2nas/backup.py",
    "mail2nas/notify.py",
    "mail2nas/archiver.py",
    "mail2nas/scanning.py",
    "mail2nas/web.py",
    "mail2nas/main.py",
    "tests/test_mapping.py",
    "tests/test_filenames.py",
    "tests/test_archiver.py",
    "tests/test_config.py",
    "tests/test_storage.py",
    "tests/test_web.py",
    "tests/test_accounts.py",
    "tests/test_addresses.py",
    "tests/test_archives.py",
    "tests/test_pickups.py",
    "tests/test_scanning.py",
    "tests/test_printers.py",
    "tests/test_printing.py",
    "tests/test_discovery.py",
    "tests/test_main.py",
    "tests/test_migrate.py",
    "tests/test_journal.py",
    "tests/test_notify.py",
    "tests/test_backup.py",
)

HEADER = """\
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
mkdir -p %(dirs)s
cd "$TARGET"

echo "Schreibe Projektdateien nach $TARGET ..."
"""

FOOTER = """
echo "Fertig: $TARGET enthaelt jetzt das komplette mail2nas-Projekt."
echo "Naechste Schritte:"
echo "  Neuinstallation:  cd $TARGET && cp .env.example .env && docker compose up -d --build"
echo "                    Startpasswort: docker compose exec mail2nas python -m mail2nas.cli password"
echo "  Update:           MAIL2NAS_OFFLINE=1 bash $TARGET/scripts/proxmox/update.sh"
echo "  Danach alles Weitere in der Weboberflaeche (http://<ip>:8080/)."
"""


def _check_complete() -> None:
    """Every module of the package has to be in the script, or the rebuilt
    project does not even import. Easy to forget when adding one."""
    embedded = set(EMBEDDED_FILES) | set(TOUCH_FILES)
    missing = sorted(
        path.relative_to(REPO).as_posix()
        for path in (REPO / "mail2nas").glob("*.py")
        if path.relative_to(REPO).as_posix() not in embedded
    )
    if missing:
        raise SystemExit(f"Not embedded in bootstrap.sh: {', '.join(missing)}")


def build() -> str:
    _check_complete()
    dirs = " ".join(f'"$TARGET"/{d}' for d in DIRECTORIES)
    out = [HEADER % {"dirs": dirs}]

    for relative in EMBEDDED_FILES:
        content = (REPO / relative).read_text(encoding="utf-8")
        if any(line.strip() == DELIMITER for line in content.splitlines()):
            raise SystemExit(
                f"{relative} contains a line equal to the heredoc delimiter {DELIMITER}"
            )
        if not content.endswith("\n"):
            content += "\n"
        out.append(f"\n# --- {relative} ---\n")
        out.append(f"cat > {relative} <<'{DELIMITER}'\n")
        out.append(content)
        out.append(f"{DELIMITER}\n")

    for relative in TOUCH_FILES:
        out.append(f"\n# --- {relative} ---\ntouch {relative}\n")

    out.append(FOOTER)
    return "".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()

    target = REPO / "scripts" / "bootstrap.sh"
    generated = build()

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != generated:
            print("bootstrap.sh is out of date - run scripts/regenerate-bootstrap.py", file=sys.stderr)
            return 1
        print("bootstrap.sh is up to date")
        return 0

    target.write_text(generated, encoding="utf-8")
    target.chmod(0o755)
    print(f"Wrote {target.relative_to(REPO)} ({len(EMBEDDED_FILES)} embedded files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
