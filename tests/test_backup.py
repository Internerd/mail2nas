"""Backing up and restoring the database, by hand and onto the NAS."""
from __future__ import annotations

import gzip
import sqlite3

import pytest

from mail2nas import backup
from mail2nas.mapping import Rule
from tests.test_archiver import _make_runtime


def _runtime(tmp_path):
    runtime = _make_runtime(tmp_path / "a")
    runtime.accounts.add(name="Buchhaltung", host="imap.example.com", user="u", password="p")
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    return runtime


def test_a_backup_is_a_compressed_copy_of_the_database(tmp_path):
    runtime = _runtime(tmp_path)

    data = backup.dump(runtime.config.state_db_path)

    assert data[:2] == backup.GZIP_MAGIC
    assert gzip.decompress(data).startswith(backup.SQLITE_MAGIC)
    counts = backup.check(data)
    assert counts["imap_accounts"] == 1
    assert counts["mapping_rules"] == 1


@pytest.mark.parametrize(
    "data, message",
    [
        (b"hallo", "keine SQLite"),
        (backup.GZIP_MAGIC + b"kaputt", "gzip"),
        (gzip.compress(b"hallo"), "keine SQLite"),
    ],
)
def test_other_files_are_refused(data, message):
    with pytest.raises(backup.BackupError, match=message):
        backup.check(data)


def test_a_database_that_is_not_ours_is_refused(tmp_path):
    other = tmp_path / "other.db"
    with sqlite3.connect(other) as conn:
        conn.execute("CREATE TABLE foo (x)")

    with pytest.raises(backup.BackupError, match="settings"):
        backup.check(other.read_bytes())


def test_restore_replaces_the_configuration_and_keeps_the_old_state(tmp_path):
    source = _runtime(tmp_path)
    data = backup.dump(source.config.state_db_path)

    target = _make_runtime(tmp_path / "b")
    target.accounts.add(name="Anderes", host="h", user="x", password="y")
    saved, counts = backup.restore(target.config.state_db_path, data, target.config.data_dir)
    target.after_restore()

    assert [a.name for a in target.accounts.all()] == ["Buchhaltung"]
    assert [r.keyword for r in target.rule_store.load()] == ["RE"]
    assert counts["imap_accounts"] == 1
    assert saved.endswith(backup.SUFFIX)
    previous = backup.check(open(saved, "rb").read())
    assert previous["imap_accounts"] == 1  # "Anderes"


def test_mail_processed_after_the_backup_stays_processed(tmp_path):
    runtime = _runtime(tmp_path)
    runtime.store.mark_processed("1:<vorher@x>")
    data = backup.dump(runtime.config.state_db_path)
    runtime.store.mark_processed("1:<nachher@x>")

    backup.restore(runtime.config.state_db_path, data, runtime.config.data_dir)
    runtime.after_restore()

    assert runtime.store.is_processed("1:<vorher@x>")
    assert runtime.store.is_processed("1:<nachher@x>")


def test_restoring_an_older_database_adds_the_new_columns(tmp_path):
    old = tmp_path / "old.db"
    with sqlite3.connect(old) as conn:
        conn.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, "
                     "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
        conn.execute(
            "CREATE TABLE imap_accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, "
            "host TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 993, ssl INTEGER NOT NULL DEFAULT 1, "
            "user TEXT NOT NULL, password TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'INBOX', "
            "mode TEXT NOT NULL DEFAULT 'poll', processed_folder TEXT NOT NULL DEFAULT '', "
            "oversized_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute("INSERT INTO imap_accounts (name, host, user, password) VALUES ('Alt','h','u','p')")

    runtime = _make_runtime(tmp_path / "b")
    backup.restore(runtime.config.state_db_path, old.read_bytes(), runtime.config.data_dir)
    runtime.after_restore()

    (account,) = runtime.accounts.all()
    assert account.name == "Alt" and account.include_seen is False
    assert runtime.journal.count() == 0


def test_only_the_last_local_copies_are_kept(tmp_path, monkeypatch):
    runtime = _runtime(tmp_path)
    stamps = iter(f"2026-01-{day:02d}_000000" for day in range(1, 20))

    class Clock:
        @staticmethod
        def now():
            class Stamp:
                def strftime(self, fmt):
                    return next(stamps)
            return Stamp()

    monkeypatch.setattr(backup, "datetime", Clock)
    for _ in range(backup.LOCAL_KEEP + 3):
        backup.save_local(runtime.config.state_db_path, runtime.config.data_dir)

    files = sorted((tmp_path / "a" / backup.LOCAL_DIR).iterdir())
    assert len(files) == backup.LOCAL_KEEP


# --- onto the NAS ---------------------------------------------------------------------


def test_validate_the_backup_settings():
    value = backup.validate({"enabled": "1", "folder": "sicherung/mail2nas", "keep": "7"}, [])

    assert value == backup.BackupSettings(True, "", "sicherung/mail2nas", 7)
    with pytest.raises(backup.BackupError):
        backup.validate({"folder": "../raus", "keep": "7"}, [])
    with pytest.raises(backup.BackupError):
        backup.validate({"folder": "x", "keep": "0"}, [])
    with pytest.raises(backup.BackupError):
        backup.validate({"folder": "x", "keep": "3", "archive": "99"}, ["1"])


def test_the_scheduler_writes_and_rotates(tmp_path):
    runtime = _runtime(tmp_path)
    store = backup.BackupStore(runtime.settings)
    store.save(backup.BackupSettings(enabled=True, folder="sicherung", keep=2))
    now = {"t": 1_000_000.0}
    scheduler = backup.BackupScheduler(runtime, clock=lambda: now["t"])
    folder = tmp_path / "a" / "sicherung"
    for stale in ("mail2nas-sicherung-2020-01-01_000000.db.gz",
                  "mail2nas-sicherung-2020-01-02_000000.db.gz"):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / stale).write_bytes(b"alt")
    (folder / "fremd.txt").write_text("bleibt")

    assert scheduler.due()
    scheduler.maybe_run()

    names = sorted(path.name for path in folder.iterdir())
    assert "fremd.txt" in names
    assert "mail2nas-sicherung-2020-01-01_000000.db.gz" not in names
    assert len([n for n in names if n.endswith(backup.SUFFIX)]) == 2
    assert runtime.backup_status.ok is True
    assert not scheduler.due()
    now["t"] += backup.BACKUP_INTERVAL
    assert scheduler.due()


def test_a_failed_backup_is_retried_hourly(tmp_path):
    runtime = _runtime(tmp_path)
    backup.BackupStore(runtime.settings).save(backup.BackupSettings(enabled=True))
    now = {"t": 1_000_000.0}
    scheduler = backup.BackupScheduler(runtime, clock=lambda: now["t"])
    runtime.archives.delete(runtime.archives.all()[0].id)

    scheduler.maybe_run()

    assert runtime.backup_status.ok is False
    assert runtime.backup_status.failing_since == now["t"]
    assert not scheduler.due()
    now["t"] += backup.RETRY_INTERVAL
    assert scheduler.due()


def test_nothing_is_due_while_switched_off(tmp_path):
    runtime = _runtime(tmp_path)

    assert not backup.BackupScheduler(runtime).due()
    assert runtime.backup_status.ok is None
