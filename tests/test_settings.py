from __future__ import annotations

import dataclasses

import pytest

from mail2nas.settings import (
    Account,
    Printer,
    Settings,
    Share,
    make_account_id,
    parse_extensions,
)
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


# --- shares -----------------------------------------------------------------


def test_first_start_creates_the_share_for_the_storage_root(tmp_path):
    config = dataclasses.replace(
        _config(tmp_path), imap_host="imap.example.com", imap_user="u", imap_password="p"
    )

    settings = Settings.load(config)

    assert [(s.id, s.path) for s in settings.shares] == [("default", config.storage_root)]


def test_config_written_before_shares_existed_gets_the_base_share(tmp_path):
    """Upgrading must not leave an installation without any archive target."""
    config = _config(tmp_path)
    Settings.path_for(config).write_text(
        "accounts:\n- {id: a, host: h, user: u, password: p}\nfallback_folder: sonstiges\n",
        encoding="utf-8",
    )

    settings = Settings.load(config)

    assert settings.fallback_folder == "sonstiges"
    assert [s.path for s in settings.shares] == [config.storage_root]


def test_shares_and_printers_survive_a_roundtrip(tmp_path):
    config = _config(tmp_path)
    Settings(
        shares=[Share(id="nas2", label="NAS 2", path="/mnt/nas2")],
        printers=[
            Printer(id="kopierer", label="Kopierer", sender="scan@x.de",
                    source_folder="scans", target_share="nas2", target_folder="eingang")
        ],
    ).save(config)

    loaded = Settings.load(config)

    assert loaded.share("nas2").path == "/mnt/nas2"
    printer = loaded.printer("kopierer")
    assert (printer.sender, printer.source_folder, printer.target_share) == (
        "scan@x.de", "scans", "nas2"
    )


def test_default_share_is_the_first_enabled_one(tmp_path):
    settings = Settings(
        shares=[
            Share(id="alt", path="/mnt/alt", enabled=False),
            Share(id="neu", path="/mnt/neu"),
        ]
    )

    assert settings.default_share().id == "neu"


def test_enabled_shares_skips_disabled_and_pathless_ones():
    settings = Settings(
        shares=[
            Share(id="ok", path="/mnt/ok"),
            Share(id="off", path="/mnt/off", enabled=False),
            Share(id="leer", path=""),
        ]
    )

    assert [s.id for s in settings.enabled_shares()] == ["ok"]


# --- printers ---------------------------------------------------------------


def test_printer_selection_by_delivery_path():
    settings = Settings(
        printers=[
            Printer(id="mail", sender="scan@x.de"),
            Printer(id="ordner", source_folder="scans"),
            Printer(id="beides", sender="a@b.c", source_folder="scans"),
            Printer(id="aus", source_folder="scans", enabled=False),
        ]
    )

    assert [p.id for p in settings.pickup_printers()] == ["ordner", "beides"]
    assert [p.id for p in settings.mail_printers()] == ["mail", "beides"]


def test_unique_ids_do_not_collide_per_kind():
    settings = Settings(
        shares=[Share(id="nas", path="/mnt/nas")],
        printers=[Printer(id="kopierer")],
    )

    assert settings.unique_share_id("nas") == "nas-2"
    assert settings.unique_printer_id("kopierer") == "kopierer-2"
    assert settings.unique_printer_id("kopierer", ignore="kopierer") == "kopierer"


# --- blocked extensions -----------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("exe,com", ["exe", "com"]),
        (".EXE, .Com", ["exe", "com"]),
        ("exe com\nbat", ["exe", "com", "bat"]),
        ("exe, exe, ,", ["exe"]),
        ("", []),
        (None, []),
        (["EXE", ".bat"], ["exe", "bat"]),
    ],
)
def test_parse_extensions_normalizes(raw, expected):
    assert parse_extensions(raw) == expected


def test_blocked_extensions_are_seeded_from_the_environment(tmp_path):
    config = dataclasses.replace(
        _config(tmp_path), blocked_extensions=frozenset({"exe", "bat"})
    )

    settings = Settings.load(config)

    assert sorted(settings.blocked_extensions) == ["bat", "exe"]


def test_blocked_extensions_reach_the_archiver_config(tmp_path):
    config = _config(tmp_path)
    settings = Settings(blocked_extensions=[".EXE", "com"])

    per_account = settings.config_for(config, Account(id="a", host="h", user="u", password="p"))

    assert per_account.blocked_extensions == frozenset({"exe", "com"})


def test_empty_extension_list_disables_the_check(tmp_path):
    config = _config(tmp_path)

    assert Settings(blocked_extensions=[]).config_common(config).blocked_extensions == frozenset()


def test_upgrade_keeps_the_quarantine_extensions_from_the_environment(tmp_path):
    """An old config file has no list - falling back to [] would disable it."""
    config = dataclasses.replace(_config(tmp_path), blocked_extensions=frozenset({"exe", "bat"}))
    Settings.path_for(config).write_text(
        "accounts:\n- {id: a, host: h, user: u, password: p}\n", encoding="utf-8"
    )

    settings = Settings.load(config)

    assert sorted(settings.blocked_extensions) == ["bat", "exe"]


def test_an_explicitly_empty_list_stays_empty(tmp_path):
    config = dataclasses.replace(_config(tmp_path), blocked_extensions=frozenset({"exe"}))
    Settings.path_for(config).write_text("blocked_extensions: []\n", encoding="utf-8")

    assert Settings.load(config).blocked_extensions == []
