from __future__ import annotations

import pytest

from mail2nas.config import Config

REQUIRED = {
    "IMAP_HOST": "imap.example.com",
    "IMAP_USER": "archiv@example.com",
    "IMAP_PASSWORD": "secret",
}


def _env(monkeypatch, **overrides):
    for key in list(REQUIRED) + [
        "IMAP_PORT", "IMAP_MODE", "POLL_INTERVAL_SECONDS", "FILENAME_PREFIX",
        "MAX_ATTACHMENT_SIZE_MB", "MAX_MESSAGE_SIZE_MB", "MAX_ATTACHMENTS_PER_MESSAGE",
        "STORAGE_BACKEND", "SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD",
        "SMB_DOMAIN", "SMB_PORT", "SMB_ROOT", "SMB_ENCRYPT", "MAPPING_PATH",
    ]:
        monkeypatch.delenv(key, raising=False)
    for key, value in {**REQUIRED, **overrides}.items():
        monkeypatch.setenv(key, value)


def test_defaults_load(monkeypatch):
    _env(monkeypatch)

    config = Config.from_env()

    assert config.imap_port == 993
    assert config.imap_mode == "poll"
    assert config.filename_prefix == "date_sender"


def test_missing_required_variable_is_reported(monkeypatch):
    _env(monkeypatch)
    monkeypatch.delenv("IMAP_PASSWORD")

    with pytest.raises(SystemExit, match="IMAP_PASSWORD"):
        Config.from_env()


@pytest.mark.parametrize("value", ["not-a-number", "", "12.5"])
def test_non_numeric_int_setting_is_rejected_clearly(monkeypatch, value):
    _env(monkeypatch, MAX_ATTACHMENT_SIZE_MB=value)

    with pytest.raises(SystemExit, match="MAX_ATTACHMENT_SIZE_MB"):
        Config.from_env()


@pytest.mark.parametrize("value", ["0", "-5"])
def test_non_positive_limits_are_rejected(monkeypatch, value):
    _env(monkeypatch, MAX_MESSAGE_SIZE_MB=value)

    with pytest.raises(SystemExit, match="MAX_MESSAGE_SIZE_MB"):
        Config.from_env()


@pytest.mark.parametrize("value", ["0", "70000"])
def test_port_out_of_range_is_rejected(monkeypatch, value):
    _env(monkeypatch, IMAP_PORT=value)

    with pytest.raises(SystemExit, match="IMAP_PORT"):
        Config.from_env()


def test_typo_in_imap_mode_fails_instead_of_silently_polling(monkeypatch):
    _env(monkeypatch, IMAP_MODE="idel")

    with pytest.raises(SystemExit, match="IMAP_MODE"):
        Config.from_env()


def test_typo_in_filename_prefix_fails(monkeypatch):
    _env(monkeypatch, FILENAME_PREFIX="date-sender")

    with pytest.raises(SystemExit, match="FILENAME_PREFIX"):
        Config.from_env()


def test_imap_mode_is_case_insensitive(monkeypatch):
    _env(monkeypatch, IMAP_MODE="IDLE")

    assert Config.from_env().imap_mode == "idle"


# --- storage backend ----------------------------------------------------------

SMB = {
    "STORAGE_BACKEND": "smb",
    "SMB_HOST": "nas.local",
    "SMB_SHARE": "Belege",
    "SMB_USER": "mail2nas",
    "SMB_PASSWORD": "secret",
}


def test_backend_defaults_to_local_so_existing_installs_keep_working(monkeypatch):
    _env(monkeypatch)

    config = Config.from_env()

    assert config.storage_backend == "local"
    assert config.storage_root == "/mnt/nas"


def test_smb_backend_loads_its_settings(monkeypatch):
    _env(monkeypatch, **SMB, SMB_ROOT="archiv/2026", SMB_DOMAIN="WORKGROUP")

    config = Config.from_env()

    assert config.storage_backend == "smb"
    assert (config.smb_host, config.smb_share) == ("nas.local", "Belege")
    assert config.smb_root == "archiv/2026"
    assert config.smb_domain == "WORKGROUP"
    assert config.smb_port == 445
    assert config.smb_encrypt is True


@pytest.mark.parametrize("missing", ["SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD"])
def test_smb_backend_reports_the_missing_setting(monkeypatch, missing):
    _env(monkeypatch, **SMB)
    monkeypatch.delenv(missing)

    with pytest.raises(SystemExit, match=missing):
        Config.from_env()


def test_local_backend_does_not_require_smb_settings(monkeypatch):
    _env(monkeypatch, STORAGE_BACKEND="local")

    assert Config.from_env().smb_host == ""


def test_unknown_backend_is_rejected(monkeypatch):
    _env(monkeypatch, STORAGE_BACKEND="nfs")

    with pytest.raises(SystemExit, match="STORAGE_BACKEND"):
        Config.from_env()


def test_empty_smb_root_means_the_share_root(monkeypatch):
    _env(monkeypatch, **SMB, SMB_ROOT="")

    assert Config.from_env().smb_root == ""


@pytest.mark.parametrize("value", ["../etc", "/etc", ".."])
def test_smb_root_cannot_escape_the_share(monkeypatch, value):
    _env(monkeypatch, **SMB, SMB_ROOT=value)

    with pytest.raises(SystemExit, match="SMB_ROOT"):
        Config.from_env()


@pytest.mark.parametrize("value", ["../mapping.yaml", "/etc/passwd"])
def test_mapping_path_cannot_escape_the_archive_root(monkeypatch, value):
    _env(monkeypatch, MAPPING_PATH=value)

    with pytest.raises(SystemExit, match="MAPPING_PATH"):
        Config.from_env()
