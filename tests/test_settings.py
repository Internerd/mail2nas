from __future__ import annotations

import dataclasses

from mail2nas.settings import Account, Settings, make_account_id
from tests.test_archiver import _make_config


def _config(tmp_path):
    data = tmp_path / "data"
    data.mkdir(exist_ok=True)
    return _make_config(tmp_path, storage_root=str(tmp_path), state_db_path=str(data / "state.db"))


def test_first_start_migrates_the_environment_configuration(tmp_path):
    """An existing single-account .env deployment must keep working."""
    config = dataclasses.replace(
        _config(tmp_path), imap_host="imap.example.com", imap_user="archiv@x", imap_password="pw"
    )

    settings = Settings.load(config)

    assert len(settings.accounts) == 1
    account = settings.accounts[0]
    assert (account.id, account.host, account.user) == ("default", "imap.example.com", "archiv@x")
    assert Settings.path_for(config).exists()


def test_settings_roundtrip_through_the_file(tmp_path):
    config = _config(tmp_path)
    settings = Settings(
        accounts=[Account(id="a", host="h", user="u", password="p")],
        fallback_folder="sonstiges",
        match_body=True,
    )
    settings.save(config)

    loaded = Settings.load(config)

    assert loaded.fallback_folder == "sonstiges"
    assert loaded.match_body is True
    assert loaded.accounts[0].password == "p"


def test_unreadable_config_falls_back_to_the_environment(tmp_path):
    config = dataclasses.replace(_config(tmp_path), imap_host="fallback.example.com")
    Settings.path_for(config).write_text("this: [is not: valid", encoding="utf-8")

    settings = Settings.load(config)

    assert settings.accounts[0].host == "fallback.example.com"


def test_enabled_accounts_skips_disabled_and_incomplete_ones(tmp_path):
    settings = Settings(
        accounts=[
            Account(id="ok", host="h", user="u", password="p"),
            Account(id="off", host="h", user="u", password="p", enabled=False),
            Account(id="incomplete", host="", user="", password=""),
        ]
    )

    assert [a.id for a in settings.enabled_accounts()] == ["ok"]


def test_unique_id_avoids_collisions(tmp_path):
    settings = Settings(accounts=[Account(id="buchhaltung", host="h", user="u", password="p")])

    assert settings.unique_id("buchhaltung") == "buchhaltung-2"
    assert settings.unique_id("buchhaltung", ignore="buchhaltung") == "buchhaltung"
    assert settings.unique_id("anderes") == "anderes"


def test_make_account_id_is_filesystem_and_yaml_safe():
    assert make_account_id("Buchhaltung Müller & Co.") == "buchhaltung-m-ller-co"
    assert make_account_id("   ") .startswith("konto-")


def test_config_for_maps_account_fields_onto_the_archiver_config(tmp_path):
    config = _config(tmp_path)
    settings = Settings(
        accounts=[],
        fallback_folder="sonstiges",
        max_attachment_size_mb=7,
    )
    account = Account(
        id="zweit", host="imap.z", user="u@z", password="pw", port=143, ssl=False,
        folder="Archiv", processed_folder="Erledigt", mode="idle",
    )

    per_account = settings.config_for(config, account)

    assert per_account.imap_host == "imap.z"
    assert per_account.imap_port == 143
    assert per_account.imap_ssl is False
    assert per_account.imap_folder == "Archiv"
    assert per_account.imap_processed_folder == "Erledigt"
    assert per_account.imap_mode == "idle"
    assert per_account.account_id == "zweit"
    # general settings come from Settings, not from the environment defaults
    assert per_account.fallback_folder == "sonstiges"
    assert per_account.max_attachment_size_mb == 7
    # infrastructure settings stay untouched
    assert per_account.storage_root == config.storage_root


def test_empty_processed_folder_becomes_none(tmp_path):
    config = _config(tmp_path)
    account = Account(id="a", host="h", user="u", password="p", processed_folder="")

    assert Settings().config_for(config, account).imap_processed_folder is None
