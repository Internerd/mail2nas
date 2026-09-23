"""The update script, exercised against rebuilt installations of every generation.

`scripts/proxmox/update.sh` is what every existing installation runs to get a
new version - whichever version it is on. So it is worth the same scrutiny as
the Python: it must update (or convert) the checkout, keep a backup of the
configuration, pick the compose files for the storage in use, wait for the
new version to take the old `.env` over, and only then tidy the `.env` up.

Docker and the upstream repository are stand-ins: a script on PATH that
records its arguments and answers the status query, and a local git
repository. Everything else is the real script.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
UPDATE_SCRIPT = REPO / "scripts" / "proxmox" / "update.sh"

# The offline install (scripts/bootstrap.sh) ships the application without the
# helper scripts, so there is nothing to test there.
pytestmark = [
    pytest.mark.skipif(not UPDATE_SCRIPT.exists(), reason="update.sh is not part of this installation"),
    pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user"),
]

FAKE_DOCKER = r"""#!/bin/sh
echo "$@" >> "$FAKE_DOCKER_LOG"
case "$*" in
  *"mail2nas.cli status"*)
    [ -n "$FAKE_NOT_READY" ] && exit 1
    printf '{\n  "options_seeded": true,\n  "initial_password_pending": false,\n  "archives": 1\n}\n'
    ;;
  *"volume inspect"*)
    [ -n "$FAKE_OLD_VOLUME" ] || exit 1
    ;;
esac
exit 0
"""

# The .env of each generation that is out there.
GEN1_CIFS_VOLUME = (
    "IMAP_HOST=imap.example.com\nIMAP_USER=archiv\nIMAP_PASSWORD=geheim\n"
    "SMB_HOST=nas\nSMB_SHARE=Belege\nSMB_USER=u\nSMB_PASSWORD=smbgeheim\nLOG_LEVEL=INFO\n"
)
GEN2_HOST_MOUNT = (
    "IMAP_HOST=imap.example.com\nIMAP_USER=archiv\nIMAP_PASSWORD=geheim\n"
    "NAS_PATH=/mnt/nas\nLOG_LEVEL=INFO\n"
)
GEN3_DIRECT_SMB = (
    'IMAP_HOST="imap.example.com"\nIMAP_PASSWORD="geheim"\nWEB_ENABLED="true"\n'
    'WEB_PORT="8090"\nWEB_PASSWORD="startpasswort"\nSTORAGE_BACKEND="smb"\n'
    'SMB_HOST="nas"\nSMB_SHARE="Belege"\nSMB_PASSWORD="smbgeheim"\nNAS_PATH="/mnt/nas"\n'
    'TZ="Europe/Vienna"\n'
)


def _git(*args, cwd: Path) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout


@pytest.fixture
def installation(tmp_path):
    """An upstream repository, a checkout of it, and a fake docker."""
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    _git("init", "-q", "-b", "main", cwd=upstream)
    for name in ("docker-compose.yml", "docker-compose.local.yml"):
        (upstream / name).write_text(f"# {name}\n", encoding="utf-8")
    (upstream / "scripts" / "proxmox").mkdir(parents=True)
    shutil.copy(UPDATE_SCRIPT, upstream / "scripts" / "proxmox" / "update.sh")
    (upstream / ".gitignore").write_text(".env\n.env.*\n", encoding="utf-8")
    (upstream / "version.txt").write_text("v1\n", encoding="utf-8")
    _git("add", "-A", cwd=upstream)
    _git("commit", "-qm", "v1", cwd=upstream)

    target = tmp_path / "opt" / "mail2nas"
    target.parent.mkdir(parents=True)
    subprocess.run(
        ["git", "clone", "-q", f"file://{upstream}", str(target)], check=True, capture_output=True
    )

    # The new version upstream, which the update is supposed to pick up.
    (upstream / "version.txt").write_text("v2\n", encoding="utf-8")
    (upstream / "mail2nas").mkdir(exist_ok=True)
    (upstream / "mail2nas" / "options.py").write_text("# neu\n", encoding="utf-8")
    _git("add", "-A", cwd=upstream)
    _git("commit", "-qm", "v2", cwd=upstream)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "docker").write_text(FAKE_DOCKER, encoding="utf-8")
    (bin_dir / "docker").chmod(0o755)
    helper_dir = tmp_path / "usr-local-bin"
    helper_dir.mkdir()
    return {
        "target": target,
        "upstream": upstream,
        "bin": bin_dir,
        "docker_log": tmp_path / "docker.log",
        "helper_dir": helper_dir,
    }


def _run(installation, **env_overrides):
    env = {
        **os.environ,
        "PATH": f"{installation['bin']}:{os.environ['PATH']}",
        "FAKE_DOCKER_LOG": str(installation["docker_log"]),
        "MAIL2NAS_TARGET_DIR": str(installation["target"]),
        "MAIL2NAS_REPO_BRANCH": "main",
        "MAIL2NAS_REPO_URL": f"file://{installation['upstream']}",
        "MAIL2NAS_BIN_DIR": str(installation["helper_dir"]),
        "MAIL2NAS_WAIT_SECONDS": "2",
        **env_overrides,
    }
    return subprocess.run(["bash", str(UPDATE_SCRIPT)], env=env, capture_output=True, text=True)


def _write_env(target: Path, text: str) -> None:
    (target / ".env").write_text(text, encoding="utf-8")


def _env(installation) -> str:
    return (installation["target"] / ".env").read_text(encoding="utf-8")


def _calls(installation) -> str:
    return installation["docker_log"].read_text(encoding="utf-8")


# --- the code ---------------------------------------------------------------------


def test_the_code_is_updated_and_the_containers_restarted(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    result = _run(installation)

    assert result.returncode == 0, result.stderr
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v2\n"
    # new files of the new version are there, not just the changed ones
    assert (installation["target"] / "mail2nas" / "options.py").exists()
    calls = _calls(installation)
    assert "build --pull" in calls
    assert "up -d --remove-orphans" in calls
    assert "mail2nas.cli status" in calls


def test_local_changes_do_not_stop_the_update(installation):
    """git reset --hard: a hand-edited file must not block a security update."""
    _write_env(installation["target"], GEN3_DIRECT_SMB)
    (installation["target"] / "version.txt").write_text("von hand\n", encoding="utf-8")

    result = _run(installation)

    assert result.returncode == 0
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v2\n"


def test_an_installation_without_git_is_turned_into_a_checkout(installation):
    """bootstrap.sh / scp installs had no .git - they are updated all the same."""
    _write_env(installation["target"], GEN3_DIRECT_SMB)
    shutil.rmtree(installation["target"] / ".git")

    result = _run(installation)

    assert result.returncode == 0, result.stderr
    assert (installation["target"] / ".git").is_dir()
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v2\n"


def test_offline_mode_builds_what_is_there(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)
    shutil.rmtree(installation["target"] / ".git")

    result = _run(installation, MAIL2NAS_OFFLINE="1",
                  MAIL2NAS_REPO_URL="file:///nirgendwo")

    assert result.returncode == 0, result.stderr
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v1\n"
    assert "build --pull" in _calls(installation)


def test_an_unreachable_upstream_explains_the_offline_route(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    result = _run(installation, MAIL2NAS_REPO_URL="file:///nirgendwo", MAIL2NAS_REPO_BRANCH="x")

    assert result.returncode != 0
    assert "MAIL2NAS_OFFLINE=1" in result.stderr


def test_running_it_twice_is_harmless(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    _run(installation)
    result = _run(installation)

    assert result.returncode == 0
    assert "Bereits auf dem aktuellen Stand" in result.stdout


# --- the configuration ------------------------------------------------------------


def test_the_old_env_is_backed_up_and_then_reduced_to_infrastructure(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    _run(installation)

    backups = list(installation["target"].glob(".env.bak.*"))
    assert len(backups) == 1
    assert backups[0].read_text(encoding="utf-8") == GEN3_DIRECT_SMB
    assert oct(backups[0].stat().st_mode & 0o777) == "0o600"
    env = _env(installation)
    for secret in ("geheim", "smbgeheim", "startpasswort", "IMAP_HOST", "STORAGE_BACKEND"):
        assert secret not in env
    assert 'WEB_PORT="8090"' in env
    assert 'TZ="Europe/Vienna"' in env
    assert oct((installation["target"] / ".env").stat().st_mode & 0o777) == "0o600"


def test_nothing_is_tidied_before_the_new_version_confirms_the_takeover(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    result = _run(installation, FAKE_NOT_READY="1")

    assert _env(installation) == GEN3_DIRECT_SMB
    assert "unveraendert" in result.stderr


def test_the_env_can_be_kept_on_request(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    _run(installation, MAIL2NAS_KEEP_ENV="1")

    assert _env(installation) == GEN3_DIRECT_SMB


def test_a_tidy_env_is_left_alone(installation):
    tidy = "WEB_PORT=8080\nTZ=Europe/Berlin\nLOG_LEVEL=INFO\n"
    _write_env(installation["target"], tidy)

    _run(installation)

    assert _env(installation) == tidy


def test_a_missing_env_is_created(installation):
    result = _run(installation)

    assert result.returncode == 0, result.stderr
    assert "WEB_PORT=8080" in _env(installation)


# --- every generation gets the right compose files ------------------------------------


def test_generation_1_cifs_volume_needs_no_mount_and_loses_the_old_volume(installation):
    _write_env(installation["target"], GEN1_CIFS_VOLUME)

    _run(installation, FAKE_OLD_VOLUME="1")

    calls = _calls(installation)
    assert "docker-compose.local.yml" not in calls
    assert "volume rm mail2nas_nas" in calls
    assert "NAS_PATH" not in _env(installation)


def test_generation_2_host_mount_keeps_its_bind_mount(installation):
    """Without the local compose file the attachments would land in the container."""
    _write_env(installation["target"], GEN2_HOST_MOUNT)

    _run(installation)

    assert "-f docker-compose.yml -f docker-compose.local.yml" in _calls(installation)
    # ... and keeps it on the next update, after the .env was tidied
    assert "NAS_PATH=/mnt/nas" in _env(installation)
    installation["docker_log"].unlink()
    _run(installation)
    assert "docker-compose.local.yml" in _calls(installation)


def test_an_explicit_local_backend_keeps_its_bind_mount(installation):
    _write_env(installation["target"], "STORAGE_BACKEND=local\nIMAP_HOST=x\n")

    _run(installation)

    assert "-f docker-compose.yml -f docker-compose.local.yml" in _calls(installation)


def test_generation_3_direct_smb_uses_only_the_main_compose_file(installation):
    """NAS_PATH was always written by that installer - it must not trigger a mount."""
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    _run(installation)

    assert "docker-compose.local.yml" not in _calls(installation)
    assert "NAS_PATH" not in _env(installation)


def test_a_fresh_installation_uses_only_the_main_compose_file(installation):
    _write_env(installation["target"], "WEB_PORT=8080\n")

    _run(installation)

    assert "docker-compose.local.yml" not in _calls(installation)


# --- the helper command and the guards -----------------------------------------------


def test_the_update_command_is_installed(installation):
    _write_env(installation["target"], GEN3_DIRECT_SMB)

    _run(installation)

    helper = installation["helper_dir"] / "mail2nas-update"
    assert os.access(helper, os.X_OK)
    assert str(installation["target"]) in helper.read_text(encoding="utf-8")


def test_a_missing_installation_is_reported(installation, tmp_path):
    result = _run(installation, MAIL2NAS_TARGET_DIR=str(tmp_path / "nirgendwo"))

    assert result.returncode != 0
    assert "existiert nicht" in result.stderr
    assert not installation["docker_log"].exists()


def test_a_directory_without_mail2nas_is_refused(installation, tmp_path):
    empty = tmp_path / "leer"
    empty.mkdir()

    result = _run(installation, MAIL2NAS_TARGET_DIR=str(empty))

    assert result.returncode != 0
    assert "install.sh" in result.stderr
