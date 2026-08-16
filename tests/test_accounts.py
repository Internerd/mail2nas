from __future__ import annotations

import pytest

from mail2nas.accounts import SETTING_ACCOUNTS_SEEDED, AccountStore, seed_from_config
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_config


@pytest.fixture
def store(tmp_path):
    return AccountStore(str(tmp_path / "state.db"))


def test_add_and_read_back_an_account(store):
    account_id = store.add(name="Buchhaltung", host="imap.example.com", user="u", password="p")

    account = store.get(account_id)

    assert account.name == "Buchhaltung"
    assert account.port == 993 and account.ssl is True
    assert account.folder == "INBOX" and account.enabled is True
    assert account.key == str(account_id)


def test_update_changes_only_what_is_passed(store):
    account_id = store.add(name="A", host="h", user="u", password="p", folder="Archiv")

    store.update(account_id, name="B")

    account = store.get(account_id)
    assert account.name == "B"
    assert account.folder == "Archiv" and account.password == "p"


def test_disabled_accounts_are_not_watched(store):
    store.add(name="An", host="h", user="u", password="p")
    store.add(name="Aus", host="h", user="u", password="p", enabled=False)

    assert [a.name for a in store.enabled()] == ["An"]
    assert len(store.all()) == 2


def test_delete_removes_the_account(store):
    account_id = store.add(name="A", host="h", user="u", password="p")

    store.delete(account_id)

    assert store.get(account_id) is None


def test_an_unknown_mode_falls_back_to_polling(store):
    account_id = store.add(name="A", host="h", user="u", password="p", mode="bogus")

    assert store.get(account_id).mode == "poll"


def test_fingerprint_changes_when_settings_change(store):
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, password="neu")

    assert store.get(account_id).fingerprint() != before


def test_renaming_does_not_restart_the_worker(store):
    """The name is cosmetic - changing it must not drop an IMAP connection."""
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, name="Anders")

    assert store.get(account_id).fingerprint() == before


# --- seeding from the environment ------------------------------------------------


def test_the_first_account_is_created_from_the_configuration(tmp_path):
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    accounts = store.all()
    assert len(accounts) == 1
    assert accounts[0].host == config.imap_host
    assert accounts[0].user == config.imap_user


def test_seeding_happens_only_once(tmp_path):
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)

    seed_from_config(store, settings, config)

    assert len(store.all()) == 1


def test_deleting_the_last_account_does_not_resurrect_it_from_the_env(tmp_path):
    """Otherwise removing a mailbox in the UI would silently come back."""
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []
    assert settings.get(SETTING_ACCOUNTS_SEEDED) == "1"
