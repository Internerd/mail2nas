from __future__ import annotations

import sqlite3

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.printers import (
    PrinterError,
    PrinterStore,
    seed_from_config,
)
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_config


@pytest.fixture
def store(tmp_path):
    return PrinterStore(str(tmp_path / "state.db"))


def _add(store, **overrides) -> int:
    fields = {"name": "Buero", "destination": "Kyocera_M2540"}
    fields.update(overrides)
    return store.add(**fields)


# --- storage ------------------------------------------------------------------


def test_add_and_read_back_a_printer(store):
    printer_id = _add(store, server="cups.lan:631", options="media=A4", copies=2)

    printer = store.get(printer_id)

    assert (printer.name, printer.destination) == ("Buero", "Kyocera_M2540")
    assert (printer.server, printer.options, printer.copies) == ("cups.lan:631", "media=A4", 2)
    assert printer.enabled is True


def test_update_changes_only_what_is_passed(store):
    printer_id = _add(store, options="media=A4")

    store.update(printer_id, name="Buchhaltung")

    printer = store.get(printer_id)
    assert printer.name == "Buchhaltung"
    assert printer.options == "media=A4"


def test_paused_printers_are_kept_but_not_offered(store):
    _add(store, name="Aktiv")
    _add(store, name="Pausiert", enabled=False)

    assert [p.name for p in store.all()] == ["Aktiv", "Pausiert"]
    assert [p.name for p in store.enabled()] == ["Aktiv"]


def test_delete_removes_the_printer(store):
    printer_id = _add(store)

    store.delete(printer_id)

    assert store.get(printer_id) is None


def test_lookup_by_the_key_a_rule_stores(store):
    printer_id = _add(store)

    assert store.by_key(str(printer_id)).id == printer_id
    assert store.by_key("") is None
    assert store.by_key("keine-zahl") is None
    assert store.by_key("9999") is None


def test_options_are_split_into_separate_arguments(store):
    printer = store.get(_add(store, options="media=A4  sides=two-sided-long-edge"))

    assert printer.option_list == ["media=A4", "sides=two-sided-long-edge"]


# --- validation ---------------------------------------------------------------


def test_a_queue_name_is_required(store):
    with pytest.raises(PrinterError):
        store.add(name="Ohne Ziel", destination="")


@pytest.mark.parametrize("destination", ["zwei woerter", "-d"])
def test_an_unusable_queue_name_is_refused(store, destination):
    with pytest.raises(PrinterError):
        _add(store, destination=destination)


def test_an_option_that_looks_like_a_flag_is_refused(store):
    # "-o media=A4" would be passed on as two arguments and silently do
    # something else than what was typed.
    with pytest.raises(PrinterError):
        _add(store, options="-o media=A4")


@pytest.mark.parametrize("copies", ["null", "0", "999"])
def test_an_unusable_copy_count_is_refused(store, copies):
    with pytest.raises(PrinterError):
        _add(store, copies=copies)


def test_the_name_defaults_to_the_queue(store):
    printer = store.get(_add(store, name=""))

    assert printer.name == "Kyocera_M2540"


# --- seeding from the environment ---------------------------------------------


def _seed_env(tmp_path, **overrides):
    config = _make_config(tmp_path, **overrides)
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    return store


def test_the_first_printer_is_created_from_the_configuration(tmp_path):
    store = _seed_env(
        tmp_path, printer_destination="Kyocera_M2540", printer_name="Buero", printer_copies=2
    )

    assert [(p.name, p.destination, p.copies) for p in store.all()] == [
        ("Buero", "Kyocera_M2540", 2)
    ]


def test_nothing_is_created_without_a_configured_queue(tmp_path):
    assert _seed_env(tmp_path).all() == []


def test_deleting_the_seeded_printer_does_not_resurrect_it(tmp_path):
    config = _make_config(tmp_path, printer_destination="Kyocera_M2540")
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []


# --- upgrading an existing installation ---------------------------------------


def test_printing_columns_are_added_to_an_existing_account_table(tmp_path):
    """An update must not require re-entering every mailbox."""
    db_path = str(tmp_path / "state.db")
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "CREATE TABLE imap_accounts ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, host TEXT NOT NULL, "
            "port INTEGER NOT NULL DEFAULT 993, ssl INTEGER NOT NULL DEFAULT 1, "
            "user TEXT NOT NULL, password TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'INBOX', "
            "mode TEXT NOT NULL DEFAULT 'poll', processed_folder TEXT NOT NULL DEFAULT '', "
            "oversized_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute(
            "INSERT INTO imap_accounts (name, host, user, password) VALUES ('Alt', 'h', 'u', 'p')"
        )

    account = AccountStore(db_path).all()[0]

    assert account.name == "Alt"
    # Defaults keep the existing behaviour: nothing printed, everything filed.
    assert account.print_attachments is False
    assert account.printer == ""
    assert account.archive_attachments is True
