from __future__ import annotations

import errno
import os
from pathlib import Path

import pytest

from mail2nas.storage import LocalStorage, SmbStorage, from_config
from tests.test_archiver import _make_config


# --- local backend ------------------------------------------------------------


def test_accepts_a_writable_storage_root(tmp_path):
    LocalStorage(str(tmp_path)).check_writable()


def test_missing_storage_root_fails_fast(tmp_path):
    """An unmounted share must not be mistaken for an empty one."""
    with pytest.raises(SystemExit, match="does not exist"):
        LocalStorage(str(tmp_path / "not-mounted")).check_writable()


def test_storage_root_that_is_a_file_fails_fast(tmp_path):
    a_file = tmp_path / "afile"
    a_file.write_text("x", encoding="utf-8")

    with pytest.raises(SystemExit, match="does not exist or is not a directory"):
        LocalStorage(str(a_file)).check_writable()


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_storage_root_fails_fast(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        with pytest.raises(SystemExit, match="not writable"):
            LocalStorage(str(readonly)).check_writable()
    finally:
        readonly.chmod(0o700)


def test_local_save_unique_creates_directories_and_avoids_overwriting(tmp_path):
    storage = LocalStorage(str(tmp_path))

    first = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"one")
    second = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"two")

    assert first != second
    assert (tmp_path / "rechnungen" / "2026" / "beleg.pdf").read_bytes() == b"one"
    assert (tmp_path / "rechnungen" / "2026" / "beleg_1.pdf").read_bytes() == b"two"


def test_local_read_text_and_modified_time(tmp_path):
    storage = LocalStorage(str(tmp_path))
    (tmp_path / "mapping.yaml").write_text("RE: rechnungen\n", encoding="utf-8")

    assert storage.read_text("mapping.yaml") == "RE: rechnungen\n"
    assert storage.modified_time("mapping.yaml") > 0

    with pytest.raises(FileNotFoundError):
        storage.modified_time("nope.yaml")


# --- SMB backend: path building (no server involved) --------------------------


def _smb(**overrides) -> SmbStorage:
    defaults = dict(host="nas.local", share="Belege", user="mail2nas", password="secret")
    defaults.update(overrides)
    return SmbStorage(**defaults)


def test_smb_builds_unc_paths():
    storage = _smb()

    assert storage._unc(("rechnungen", "2026"), "beleg.pdf") == (
        "\\\\nas.local\\Belege\\rechnungen\\2026\\beleg.pdf"
    )
    assert storage._unc(()) == "\\\\nas.local\\Belege"


def test_smb_root_prefixes_every_path():
    storage = _smb(root="archiv/2026")

    assert storage._unc(("rechnungen",)) == "\\\\nas.local\\Belege\\archiv\\2026\\rechnungen"
    assert storage.description == "//nas.local/Belege/archiv/2026"


def test_smb_display_uses_forward_slashes():
    assert _smb().display(("rechnungen",), "beleg.pdf") == "//nas.local/Belege/rechnungen/beleg.pdf"


def test_smb_root_cannot_escape_the_share():
    with pytest.raises(ValueError):
        _smb(root="../../etc")


# --- SMB backend: reconnect behaviour -----------------------------------------


def test_smb_retries_once_on_a_failed_call(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) == 1:
            raise OSError(errno.ECONNRESET, "connection reset")
        return "ok"

    assert storage._with_reconnect("write", flaky) == "ok"
    assert len(attempts) == 2


def test_smb_missing_file_is_reported_as_filenotfound_without_retrying(monkeypatch):
    """The mapping file may legitimately not exist - that is not a broken session."""
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    attempts = []

    def missing():
        attempts.append(1)
        raise OSError(errno.ENOENT, "no such file")

    with pytest.raises(FileNotFoundError):
        storage._with_reconnect("stat", missing)
    assert len(attempts) == 1


def test_smb_reraises_when_the_retry_also_fails(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)

    def always_broken():
        raise OSError(errno.EACCES, "permission denied")

    with pytest.raises(OSError, match="permission denied"):
        storage._with_reconnect("write", always_broken)


# --- backend selection ---------------------------------------------------------


def test_from_config_selects_the_configured_backend(tmp_path):
    local = from_config(_make_config(tmp_path, storage_backend="local"))
    assert isinstance(local, LocalStorage)

    smb = from_config(
        _make_config(
            tmp_path,
            storage_backend="smb",
            smb_host="nas.local",
            smb_share="Belege",
            smb_user="u",
            smb_password="p",
        )
    )
    assert isinstance(smb, SmbStorage)
    assert smb.description == "//nas.local/Belege"


# --- listing and moving files (pickup folders) --------------------------------


def _drop(path: Path, content: bytes = b"scan") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def test_list_files_finds_files_in_subfolders(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf")
    _drop(tmp_path / "scans" / "anna" / "b.pdf")

    found = storage.list_files(("scans",))

    assert sorted(entry.relative for entry in found) == ["scans/a.pdf", "scans/anna/b.pdf"]
    assert all(entry.size == 4 for entry in found)


def test_list_files_skips_hidden_entries(tmp_path):
    """Our own temporary files start with a dot - they are not documents."""
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / ".mail2nas-tmp-1")
    _drop(tmp_path / "scans" / "real.pdf")

    assert [entry.name for entry in storage.list_files(("scans",))] == ["real.pdf"]


def test_list_files_on_a_missing_folder_is_empty(tmp_path):
    assert LocalStorage(str(tmp_path)).list_files(("gibtsnicht",)) == []


def test_list_files_stops_at_the_depth_limit(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a" / "b" / "c" / "deep.pdf")

    assert storage.list_files(("scans",), max_depth=2) == []
    assert len(storage.list_files(("scans",), max_depth=5)) == 1


def test_move_unique_moves_and_removes_the_original(tmp_path):
    storage = LocalStorage(str(tmp_path))
    source = _drop(tmp_path / "scans" / "a.pdf", b"inhalt")

    out = storage.move_unique(("scans", "a.pdf"), ("eingang",), "2026-01-01_a.pdf")

    assert not source.exists()
    assert Path(out).read_bytes() == b"inhalt"


def test_move_unique_never_overwrites(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "eingang" / "a.pdf", b"alt")
    _drop(tmp_path / "scans" / "a.pdf", b"neu")

    out = storage.move_unique(("scans", "a.pdf"), ("eingang",), "a.pdf")

    assert Path(out).name == "a_1.pdf"
    assert (tmp_path / "eingang" / "a.pdf").read_bytes() == b"alt"


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_a_source_that_cannot_be_deleted_leaves_no_copy(tmp_path):
    """Copying without deleting would re-import the same scan for ever."""
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf")
    (tmp_path / "scans").chmod(0o500)
    try:
        with pytest.raises(OSError):
            storage.move_unique(("scans", "a.pdf"), ("eingang",), "a.pdf")
        assert list((tmp_path / "eingang").glob("*")) == []
    finally:
        (tmp_path / "scans").chmod(0o700)


def test_read_bytes(tmp_path):
    storage = LocalStorage(str(tmp_path))
    _drop(tmp_path / "scans" / "a.pdf", b"%PDF-1.4")

    assert storage.read_bytes("scans/a.pdf") == b"%PDF-1.4"
