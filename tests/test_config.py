from __future__ import annotations

import pytest

from mail2nas.config import Config, parse_extension_list
from mail2nas.legacy import LEGACY_VARIABLES, LegacyEnv

INFRA = ("STATE_DB_PATH", "WEB_HOST", "WEB_PORT", "WEB_PASSWORD", "WEB_COOKIE_SECURE",
         "LP_BINARY", "LPSTAT_BINARY")


@pytest.fixture
def clean_env(monkeypatch):
    for key in (*INFRA, *LEGACY_VARIABLES, "NAS_PATH"):
        monkeypatch.delenv(key, raising=False)
    return monkeypatch


# --- the container configuration ----------------------------------------------


def test_an_empty_env_is_enough_to_start(clean_env):
    """No mailbox, no share, no password: all of that is set up in the web UI."""
    config = Config.from_env()

    assert config.state_db_path == "/data/state.db"
    assert config.web_port == 8080
    assert config.web_password == ""


def test_old_variables_do_not_break_the_container_config(clean_env):
    clean_env.setenv("IMAP_MODE", "tippfehler")
    clean_env.setenv("MAX_ATTACHMENT_SIZE_MB", "viel")

    Config.from_env()  # must not raise - those values are the legacy reader's job


@pytest.mark.parametrize("value", ["0", "70000", "achtzig"])
def test_an_unusable_web_port_is_reported(clean_env, value):
    clean_env.setenv("WEB_PORT", value)

    with pytest.raises(SystemExit, match="WEB_PORT"):
        Config.from_env()


def test_lpstat_is_found_next_to_lp(clean_env):
    clean_env.setenv("LP_BINARY", "/opt/cups/bin/lp")

    assert Config.from_env().lpstat_binary == "/opt/cups/bin/lpstat"


def test_the_data_directory_is_next_to_the_database(clean_env):
    clean_env.setenv("STATE_DB_PATH", "/srv/mail2nas/state.db")

    assert Config.from_env().data_dir == "/srv/mail2nas"


def test_extension_lists_accept_every_separator_people_type():
    assert parse_extension_list(".EXE, com; bat  js") == {"exe", "com", "bat", "js"}


# --- reading an older .env ------------------------------------------------------


def test_a_fresh_env_describes_nothing_to_take_over(clean_env):
    legacy = LegacyEnv.from_environ()

    assert not legacy.has_mailbox
    assert not legacy.has_archive
    assert not legacy.has_options


def test_generation_1_docker_cifs_volume_becomes_direct_smb():
    """SMB credentials in the .env, no backend: Docker used to mount the share.

    Treating it as a mount would write into an empty directory inside the
    container - the one mistake an update must not make.
    """
    legacy = LegacyEnv.from_environ({
        "IMAP_HOST": "imap.x", "IMAP_USER": "u", "IMAP_PASSWORD": "p",
        "SMB_HOST": "nas", "SMB_SHARE": "Belege", "SMB_USER": "a", "SMB_PASSWORD": "b",
    })

    assert legacy.storage_backend == "smb"
    assert (legacy.smb_host, legacy.smb_share) == ("nas", "Belege")


def test_generation_2_host_mount_stays_a_mounted_directory():
    legacy = LegacyEnv.from_environ({
        "IMAP_HOST": "imap.x", "IMAP_USER": "u", "IMAP_PASSWORD": "p", "NAS_PATH": "/mnt/nas",
    })

    assert legacy.storage_backend == "local"
    assert legacy.storage_root == "/mnt/nas"


@pytest.mark.parametrize("backend", ["smb", "local"])
def test_an_explicit_backend_wins(backend):
    legacy = LegacyEnv.from_environ({
        "STORAGE_BACKEND": backend, "SMB_HOST": "nas", "SMB_SHARE": "Belege",
        "SMB_USER": "a", "SMB_PASSWORD": "b",
    })

    assert legacy.storage_backend == backend


def test_smb_without_a_share_is_not_taken_over():
    assert LegacyEnv.from_environ({"STORAGE_BACKEND": "smb", "SMB_HOST": "nas"}).storage_backend == ""


@pytest.mark.parametrize(
    "name,value,attribute,expected",
    [
        ("IMAP_PORT", "abc", "imap_port", 993),
        ("IMAP_MODE", "sofort", "imap_mode", "poll"),
        ("FILENAME_PREFIX", "egal", "filename_prefix", "date_sender"),
        ("MAX_ATTACHMENT_SIZE_MB", "0", "max_attachment_size_mb", 25),
        ("PRINTER_COPIES", "99", "printer_copies", 1),
    ],
)
def test_a_broken_old_value_falls_back_instead_of_stopping(name, value, attribute, expected):
    assert getattr(LegacyEnv.from_environ({name: value}), attribute) == expected


def test_old_values_are_read_with_their_old_meaning():
    legacy = LegacyEnv.from_environ({
        "IMAP_MODE": "IDLE", "MATCH_BODY": "true", "FALLBACK_FOLDER": "sonstiges",
        "BLOCKED_EXTENSIONS": "exe,js", "POLL_INTERVAL_SECONDS": "60",
    })

    assert legacy.imap_mode == "idle"
    assert legacy.match_body is True
    assert legacy.fallback_folder == "sonstiges"
    assert legacy.blocked_extensions == {"exe", "js"}
    assert legacy.poll_interval == 60
    assert legacy.has_options
