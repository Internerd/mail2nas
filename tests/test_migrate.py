"""Coming from an older installation, and the commands the scripts use."""
from __future__ import annotations

import io
import json

import pytest

from mail2nas import cli
from mail2nas.migrate import migration_status
from mail2nas.options import Options, OptionsError, OptionsStore, as_form, validate
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_runtime

OLD_ENV = {
    "IMAP_HOST": "imap.example.com", "IMAP_USER": "archiv@example.com",
    "IMAP_PASSWORD": "geheim", "IMAP_MODE": "idle",
    "STORAGE_BACKEND": "local", "STORAGE_ROOT": "/mnt/nas",
    "FALLBACK_FOLDER": "sonstiges", "MATCH_BODY": "true", "POLL_INTERVAL_SECONDS": "120",
    "BLOCKED_EXTENSIONS": "exe,js", "DRY_RUN": "true", "PRINTER_DESTINATION": "Buero",
    "MAPPING_PATH": "config/regeln.yaml",
}


# --- the .env of an older version is carried over, once -------------------------


def test_an_old_env_arrives_complete_in_the_database(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    account = runtime.accounts.all()[0]
    assert (account.host, account.user, account.mode) == ("imap.example.com", "archiv@example.com", "idle")
    assert [(a.backend, a.path) for a in runtime.archives.all()] == [("local", "/mnt/nas")]
    assert [p.destination for p in runtime.printers.all()] == ["Buero"]
    options = runtime.options
    assert options.fallback_folder == "sonstiges"
    assert options.match_body is True
    assert options.poll_interval == 120
    assert options.blocked_extensions == {"exe", "js"}
    assert options.dry_run is True
    assert runtime.settings.get("mapping_path") == "config/regeln.yaml"


def test_after_the_first_start_the_env_no_longer_matters(tmp_path):
    _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    runtime = _make_runtime(tmp_path, with_archive=False,
                            environ={**OLD_ENV, "FALLBACK_FOLDER": "anders"})

    assert runtime.options.fallback_folder == "sonstiges"
    assert len(runtime.accounts.all()) == 1


def test_values_edited_in_the_old_ui_beat_the_env(tmp_path):
    """The quarantine list was editable before - that is the newer statement."""
    settings = SettingsStore(str(tmp_path / "state.db"))
    settings.set("blocked_extensions", "exe,scr")

    runtime = _make_runtime(tmp_path, with_archive=False, environ=OLD_ENV)

    assert runtime.options.blocked_extensions == {"exe", "scr"}


def test_a_fresh_installation_starts_with_defaults_and_nothing_else(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)

    assert runtime.options == Options()
    assert runtime.accounts.all() == []
    assert runtime.archives.all() == []
    assert all(migration_status(runtime)[key] for key in
               ("options_seeded", "accounts_seeded", "archives_seeded", "printers_seeded"))


# --- the settings themselves --------------------------------------------------


def test_every_setting_round_trips_through_the_form():
    options = Options(fallback_folder="a/b", match_body=True, dry_run=True,
                      printable_extensions=frozenset({"pdf"}))

    assert validate(as_form(options)) == options


def test_a_value_broken_in_the_database_falls_back_to_its_default(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))
    settings.set("opt.poll_interval", "nie")

    assert OptionsStore(settings).load().poll_interval == Options().poll_interval


@pytest.mark.parametrize("prefix", ["", "datum"])
def test_an_unknown_filename_prefix_is_refused(prefix):
    form = as_form(Options())
    form["filename_prefix"] = prefix or "x"

    with pytest.raises(OptionsError):
        validate(form)


# --- the maintenance commands ------------------------------------------------------


@pytest.fixture
def container(tmp_path, monkeypatch):
    """Point the CLI at a database in tmp_path, like STATE_DB_PATH in the container."""
    for key in OLD_ENV:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("STATE_DB_PATH", str(tmp_path / "state.db"))
    return tmp_path


def test_status_reports_what_the_update_script_waits_for(container, capsys):
    assert cli.main(["status"]) == 0

    status = json.loads(capsys.readouterr().out)
    assert status["options_seeded"] and status["rules_migrated"] is False
    assert status["archives"] == 0


def test_the_generated_password_can_be_shown_and_reset(container, capsys):
    from mail2nas.web import SETTING_PASSWORD_HASH, ensure_password

    settings = SettingsStore(str(container / "state.db"))
    generated = ensure_password(settings, "", str(container))

    assert cli.main(["password"]) == 0
    assert capsys.readouterr().out.strip() == generated

    before = settings.get(SETTING_PASSWORD_HASH)
    assert cli.main(["reset-password"]) == 0
    new = capsys.readouterr().out.strip()
    assert new != generated
    assert settings.get(SETTING_PASSWORD_HASH) != before


def test_password_says_so_when_it_was_already_changed(container, capsys):
    assert cli.main(["password"]) == 1


def _archive_to_smb(monkeypatch, payload: dict, works: bool = True):
    from mail2nas import storage as storage_module

    class FakeSmb:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def check_writable(self):
            if not works:
                raise SystemExit("STATUS_LOGON_FAILURE")

        def close(self):
            pass

    monkeypatch.setattr(storage_module, "SmbStorage", FakeSmb)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    return cli.main(["archive-to-smb"])


SMB = {"host": "nas.lan", "share": "Belege", "user": "archiv", "password": "geheim"}


def test_a_host_mount_can_be_switched_to_direct_smb(container, monkeypatch):
    runtime = _make_runtime(container, with_archive=False)
    runtime.archives.add(name="Archiv", backend="local", path="/mnt/nas")

    assert _archive_to_smb(monkeypatch, SMB) == 0

    archive = runtime.archives.all()[0]
    assert (archive.backend, archive.host, archive.share, archive.path) == ("smb", "nas.lan", "Belege", "")


def test_a_failed_smb_test_leaves_the_mount_in_place(container, monkeypatch):
    runtime = _make_runtime(container, with_archive=False)
    runtime.archives.add(name="Archiv", backend="local", path="/mnt/nas")

    assert _archive_to_smb(monkeypatch, SMB, works=False) == 1

    assert runtime.archives.all()[0].backend == "local"


def test_nothing_to_switch_is_reported_as_such(container, monkeypatch):
    _make_runtime(container, with_archive=False)

    assert _archive_to_smb(monkeypatch, SMB) == 2
