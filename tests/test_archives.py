from __future__ import annotations

import pytest

from mail2nas.archives import (
    Archive,
    ArchiveError,
    ArchiveStore,
    StorageSet,
    seed_from_config,
)
from mail2nas.state import SettingsStore
from mail2nas.storage import LocalStorage, SmbStorage
from tests.test_archiver import _make_config


def _store(tmp_path) -> ArchiveStore:
    return ArchiveStore(str(tmp_path / "state.db"))


def _local(tmp_path, **fields) -> int:
    values = dict(name="Haupt", backend="local", path=str(tmp_path))
    values.update(fields)
    return _store(tmp_path).add(**values)


# --- validation ---------------------------------------------------------------


def test_an_smb_archive_needs_server_share_and_credentials(tmp_path):
    store = _store(tmp_path)

    for missing in ("host", "share", "user", "password"):
        fields = dict(
            name="NAS", backend="smb", host="nas.lan", share="Belege", user="u", password="p"
        )
        fields[missing] = ""
        with pytest.raises(ArchiveError):
            store.add(**fields)


def test_a_mounted_archive_needs_an_absolute_path(tmp_path):
    store = _store(tmp_path)

    with pytest.raises(ArchiveError, match="absoluter Pfad"):
        store.add(name="Lokal", backend="local", path="relativ/pfad")


def test_an_unknown_backend_is_rejected(tmp_path):
    with pytest.raises(ArchiveError, match="Unbekannte Art"):
        _store(tmp_path).add(name="X", backend="ftp", path="/mnt/x")


def test_a_subfolder_that_escapes_the_share_is_rejected(tmp_path):
    with pytest.raises(ArchiveError, match="Unterordner"):
        _store(tmp_path).add(
            name="NAS", backend="smb", host="h", share="s", user="u", password="p",
            root="../woanders",
        )


def test_the_port_has_to_be_a_number(tmp_path):
    with pytest.raises(ArchiveError, match="Zahl"):
        _store(tmp_path).add(
            name="NAS", backend="smb", host="h", share="s", user="u", password="p", port="vier",
        )


def test_the_name_defaults_to_the_share(tmp_path):
    store = _store(tmp_path)

    archive_id = store.add(
        backend="smb", host="nas.lan", share="Belege", user="u", password="p"
    )

    assert store.get(archive_id).name == "Belege"


# --- store --------------------------------------------------------------------


def test_add_and_read_back(tmp_path):
    store = _store(tmp_path)

    archive_id = store.add(
        name="NAS Buero", backend="smb", host="nas.lan", share="Belege",
        user="archiv", password="geheim", root="2026", port=445, encrypt=False,
    )

    archive = store.get(archive_id)
    assert archive.location() == "//nas.lan/Belege/2026"
    assert archive.encrypt is False
    assert archive.key == str(archive_id)


def test_update_keeps_the_fields_not_sent(tmp_path):
    store = _store(tmp_path)
    archive_id = store.add(
        name="NAS", backend="smb", host="nas.lan", share="Belege", user="u", password="geheim"
    )

    store.update(archive_id, name="NAS Buero")

    archive = store.get(archive_id)
    assert (archive.name, archive.password) == ("NAS Buero", "geheim")


def test_the_default_is_the_first_enabled_archive(tmp_path):
    store = _store(tmp_path)
    first = store.add(name="Alt", backend="local", path="/mnt/alt", enabled=False)
    second = store.add(name="Neu", backend="local", path="/mnt/neu")

    assert store.default().id == second
    assert store.get(first).enabled is False


def test_by_key_survives_nonsense(tmp_path):
    store = _store(tmp_path)

    assert store.by_key("keine-zahl") is None
    assert store.by_key("999") is None


# --- seeding from the environment ---------------------------------------------


def test_seeding_takes_the_smb_settings_from_the_env(tmp_path):
    config = _make_config(
        tmp_path, storage_backend="smb", smb_host="nas.lan", smb_share="Belege",
        smb_user="archiv", smb_password="geheim",
    )
    store = _store(tmp_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    archive = store.default()
    assert (archive.backend, archive.host, archive.share) == ("smb", "nas.lan", "Belege")


def test_seeding_takes_the_mounted_directory_from_the_env(tmp_path):
    config = _make_config(tmp_path, storage_backend="local")
    store = _store(tmp_path)

    seed_from_config(store, SettingsStore(config.state_db_path), config)

    archive = store.default()
    assert (archive.backend, archive.path) == ("local", config.storage_root)


def test_seeding_happens_only_once(tmp_path):
    """Deleting the last archive in the UI must not resurrect it on restart."""
    config = _make_config(tmp_path, storage_backend="local")
    store = _store(tmp_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)

    for archive in store.all():
        store.delete(archive.id)
    seed_from_config(store, settings, config)

    assert store.all() == []


# --- storage set --------------------------------------------------------------


def test_without_archives_everything_uses_the_env_storage(tmp_path):
    fallback = LocalStorage(str(tmp_path))
    storages = StorageSet(None, fallback)

    assert storages.get("") is fallback
    assert storages.get("7") is fallback


def test_a_named_archive_gets_its_own_storage(tmp_path):
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    second = store.add(name="NAS 2", backend="local", path=str(tmp_path / "zwei"))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    assert storages.get(str(second)).description == str(tmp_path / "zwei")
    assert storages.default().description == str(tmp_path)


def test_the_storage_is_reused_until_the_archive_changes(tmp_path):
    """An SMB session per attachment would be absurd - so it is cached."""
    store = _store(tmp_path)
    archive_id = store.add(name="Haupt", backend="local", path=str(tmp_path))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    first = storages.get(str(archive_id))
    assert storages.get(str(archive_id)) is first

    store.update(archive_id, path=str(tmp_path / "woanders"))
    rebuilt = storages.get(str(archive_id))

    assert rebuilt is not first
    assert rebuilt.description == str(tmp_path / "woanders")


def test_an_unknown_or_paused_archive_falls_back_to_the_default(tmp_path):
    """A rule may name an archive that was deleted - file it, do not lose it."""
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    paused = store.add(name="Aus", backend="local", path=str(tmp_path / "aus"), enabled=False)
    storages = StorageSet(store, LocalStorage(str(tmp_path)))

    assert storages.get("999").description == str(tmp_path)
    assert storages.get(str(paused)).description == str(tmp_path)


def test_an_smb_archive_builds_an_smb_storage(tmp_path):
    archive = Archive(
        id=1, name="NAS", backend="smb", host="nas.lan", share="Belege", user="u",
        password="p", domain="", port=445, root="", encrypt=True, path="", enabled=True,
    )

    assert isinstance(archive.to_storage(), SmbStorage)


def test_closing_releases_every_connection(tmp_path):
    store = _store(tmp_path)
    store.add(name="Haupt", backend="local", path=str(tmp_path))
    storages = StorageSet(store, LocalStorage(str(tmp_path)))
    storages.default()

    storages.close()  # must not raise, and drops the cache

    assert storages.default() is not None
