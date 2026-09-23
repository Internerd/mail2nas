"""A few maintenance commands, for the install and update scripts.

Run inside the container:

    docker compose exec mail2nas python -m mail2nas.cli status
    docker compose exec mail2nas python -m mail2nas.cli password
    docker compose exec mail2nas python -m mail2nas.cli reset-password
    echo '{"host": ...}' | docker compose exec -T mail2nas python -m mail2nas.cli archive-to-smb

Everything else is configured in the web UI; these exist for the handful of
things a script has to do without a browser: find out whether an update has
taken the old configuration over, show the generated first password, get
back in after a forgotten one, and move an installation off a host mount.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys

from .archives import ArchiveError
from .config import Config
from .main import build_runtime
from .migrate import migration_status


def _status(runtime, config) -> int:
    from .web import SETTING_PASSWORD_HASH, read_initial_password

    status = migration_status(runtime)
    default = runtime.default_archive()
    status.update(
        {
            "password_set": bool(runtime.settings.get(SETTING_PASSWORD_HASH)),
            "initial_password_pending": read_initial_password(config.data_dir) is not None,
            "mailboxes": len(runtime.accounts.all()),
            "archives": len(runtime.archives.all()),
            "default_archive": default.location() if default else None,
            "default_archive_backend": default.backend if default else None,
            "rules": runtime.rule_store.count(),
            "printers": len(runtime.printers.all()),
        }
    )
    print(json.dumps(status, indent=2, ensure_ascii=False))
    return 0


def _password(config) -> int:
    from .web import read_initial_password

    password = read_initial_password(config.data_dir)
    if password is None:
        print("Kein Startpasswort mehr hinterlegt - es wurde bereits geaendert.", file=sys.stderr)
        print("Vergessen? python -m mail2nas.cli reset-password", file=sys.stderr)
        return 1
    print(password)
    return 0


def _reset_password(runtime, config) -> int:
    from .web import _write_initial_password, generate_password, set_password

    password = generate_password()
    set_password(runtime.settings, password, config.data_dir)
    _write_initial_password(config.data_dir, password)
    print(password)
    return 0


def _archive_to_smb(runtime) -> int:
    """Switch the mounted-directory archive over to direct SMB.

    For installations from the time the share was mounted on the Proxmox
    host: the host script knows the credentials (they are in a file there)
    and pipes them in as JSON. Nothing changes unless a write test with the
    new settings succeeds - a typo must not cut the archive off.
    """
    try:
        data = json.load(sys.stdin)
    except ValueError as exc:
        print(f"Ungueltige Eingabe: {exc}", file=sys.stderr)
        return 1

    path = data.pop("mount_path", "/mnt/nas")
    candidates = [a for a in runtime.archives.all() if a.backend == "local" and a.path == path]
    if not candidates:
        print(f"Kein Archiv mit gemountetem Verzeichnis {path} - nichts umzustellen.")
        return 2
    archive = candidates[0]

    from .archives import validate

    fields = {
        "name": archive.name if archive.name != "Archiv" else (data.get("share") or archive.name),
        "backend": "smb",
        "host": data.get("host", ""),
        "share": data.get("share", ""),
        "user": data.get("user", ""),
        "password": data.get("password", ""),
        "domain": data.get("domain", ""),
        "port": data.get("port", 445),
        "root": data.get("root", ""),
        "encrypt": data.get("encrypt", True),
        "path": "",
        "enabled": archive.enabled,
    }
    try:
        values = validate(fields)
    except ArchiveError as exc:
        print(f"Zugangsdaten unvollstaendig: {exc}", file=sys.stderr)
        return 1

    from .storage import SmbStorage

    probe = SmbStorage(
        host=values["host"], share=values["share"], user=values["user"],
        password=values["password"], domain=values["domain"] or None, port=values["port"],
        root=values["root"], encrypt=bool(values["encrypt"]),
    )
    try:
        probe.check_writable()
    except BaseException as exc:  # noqa: BLE001 - check_writable reports via SystemExit
        if isinstance(exc, KeyboardInterrupt):
            raise
        print(f"SMB-Test fehlgeschlagen, Archiv bleibt unveraendert: {exc}", file=sys.stderr)
        return 1
    finally:
        probe.close()

    runtime.archives.update(archive.id, **fields)
    print(f"Archiv {archive.name!r} schreibt jetzt direkt auf //{values['host']}/{values['share']}.")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mail2nas.cli", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "command", choices=("status", "password", "reset-password", "archive-to-smb")
    )
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)

    config = Config.from_env()
    if args.command == "password":
        return _password(config)
    runtime = build_runtime(config)
    if args.command == "status":
        return _status(runtime, config)
    if args.command == "reset-password":
        return _reset_password(runtime, config)
    return _archive_to_smb(runtime)


if __name__ == "__main__":
    raise SystemExit(main())
