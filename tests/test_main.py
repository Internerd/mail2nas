from __future__ import annotations

import os

import pytest

from mail2nas.main import _check_storage_root
from tests.test_archiver import _make_config


def test_accepts_a_writable_storage_root(tmp_path):
    _check_storage_root(_make_config(tmp_path, storage_root=str(tmp_path)))


def test_missing_storage_root_fails_fast(tmp_path):
    """An unmounted share must not be mistaken for an empty one."""
    missing = tmp_path / "not-mounted"

    with pytest.raises(SystemExit, match="does not exist"):
        _check_storage_root(_make_config(tmp_path, storage_root=str(missing)))


def test_storage_root_that_is_a_file_fails_fast(tmp_path):
    a_file = tmp_path / "afile"
    a_file.write_text("x", encoding="utf-8")

    with pytest.raises(SystemExit, match="does not exist or is not a directory"):
        _check_storage_root(_make_config(tmp_path, storage_root=str(a_file)))


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_storage_root_fails_fast(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        with pytest.raises(SystemExit, match="not writable"):
            _check_storage_root(_make_config(tmp_path, storage_root=str(readonly)))
    finally:
        readonly.chmod(0o700)
