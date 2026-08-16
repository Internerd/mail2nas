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

DIRECTORIES = ("mail2nas", "config", "tests")

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
    "mail2nas/config.py",
    "mail2nas/storage.py",
    "mail2nas/mapping.py",
    "mail2nas/filenames.py",
    "mail2nas/state.py",
    "mail2nas/archiver.py",
    "mail2nas/web.py",
    "mail2nas/main.py",
    "tests/test_mapping.py",
    "tests/test_filenames.py",
    "tests/test_archiver.py",
    "tests/test_config.py",
    "tests/test_storage.py",
    "tests/test_web.py",
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
echo "  cd $TARGET"
echo "  cp .env.example .env && \\$EDITOR .env"
echo "  # siehe README.md (Abschnitt 'Installation, Variante 2') fuer den Rest"
"""


def build() -> str:
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
