"""The update script, exercised against a rebuilt installation.

`scripts/proxmox/update.sh` is what every existing installation runs to get a
new version, so it is worth the same scrutiny as the Python: it must update
the checkout, keep the configuration, and start the containers with the right
compose files for the storage backend in use.

Docker and the upstream repository are stand-ins: a script on PATH that
records its arguments, and a local git repository. Everything else - the
guards, the backup, the fetch, the backend detection - is the real script.
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
pytestmark = pytest.mark.skipif(
    not UPDATE_SCRIPT.exists(), reason="update.sh is not part of this installation"
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
    (upstream / "mail2nas" / "archives.py").write_text("# neu\n", encoding="utf-8")
    _git("add", "-A", cwd=upstream)
    _git("commit", "-qm", "v2", cwd=upstream)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    docker_log = tmp_path / "docker.log"
    (bin_dir / "docker").write_text(
        f'#!/bin/sh\necho "$@" >> {docker_log}\nexit 0\n', encoding="utf-8"
    )
    (bin_dir / "docker").chmod(0o755)
    return {
        "target": target,
        "upstream": upstream,
        "bin": bin_dir,
        "docker_log": docker_log,
    }


def _run(installation, **env_overrides):
    env = {
        **os.environ,
        "PATH": f"{installation['bin']}:{os.environ['PATH']}",
        "MAIL2NAS_TARGET_DIR": str(installation["target"]),
        "MAIL2NAS_REPO_BRANCH": "main",
        **env_overrides,
    }
    return subprocess.run(
        ["bash", str(UPDATE_SCRIPT)], env=env, capture_output=True, text=True
    )


def _write_env(target: Path, text: str = "IMAP_HOST=imap.example.com\n") -> None:
    (target / ".env").write_text(text, encoding="utf-8")


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_the_code_is_updated_and_the_containers_restarted(installation):
    _write_env(installation["target"])

    result = _run(installation)

    assert result.returncode == 0, result.stderr
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v2\n"
    # new files of the new version are there, not just the changed ones
    assert (installation["target"] / "mail2nas" / "archives.py").exists()
    calls = installation["docker_log"].read_text(encoding="utf-8")
    assert "build --pull" in calls
    assert "up -d" in calls


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_the_configuration_survives_and_is_backed_up(installation):
    secret = "IMAP_HOST=imap.example.com\nIMAP_PASSWORD=geheim\n"
    _write_env(installation["target"], secret)

    _run(installation)

    assert (installation["target"] / ".env").read_text(encoding="utf-8") == secret
    backups = list(installation["target"].glob(".env.bak.*"))
    assert len(backups) == 1
    assert backups[0].read_text(encoding="utf-8") == secret


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_a_mounted_installation_keeps_its_bind_mount(installation):
    """Without the local compose file the attachments would land in the container."""
    _write_env(installation["target"], "STORAGE_BACKEND=local\n")

    _run(installation)

    calls = installation["docker_log"].read_text(encoding="utf-8")
    assert "-f docker-compose.yml -f docker-compose.local.yml" in calls


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_an_smb_installation_uses_only_the_main_compose_file(installation):
    _write_env(installation["target"], 'STORAGE_BACKEND="smb"\n')

    result = _run(installation)

    calls = installation["docker_log"].read_text(encoding="utf-8")
    assert "docker-compose.local.yml" not in calls
    assert "Storage-Backend laut .env: smb" in result.stdout


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_an_env_without_a_backend_is_treated_as_mounted(installation):
    """An installation from before the SMB backend must keep its mount."""
    _write_env(installation["target"], "IMAP_HOST=x\n")

    _run(installation)

    assert "docker-compose.local.yml" in installation["docker_log"].read_text(encoding="utf-8")


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_running_it_twice_is_harmless(installation):
    _write_env(installation["target"])

    _run(installation)
    result = _run(installation)

    assert result.returncode == 0
    assert "Bereits auf dem aktuellen Stand" in result.stdout
    assert len(list(installation["target"].glob(".env.bak.*"))) >= 1


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_local_changes_do_not_stop_the_update(installation):
    """git reset --hard: a hand-edited file must not block a security update."""
    _write_env(installation["target"])
    (installation["target"] / "version.txt").write_text("von hand\n", encoding="utf-8")

    result = _run(installation)

    assert result.returncode == 0
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v2\n"


# --- the guards ----------------------------------------------------------------


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_a_missing_installation_is_reported(installation, tmp_path):
    result = _run(installation, MAIL2NAS_TARGET_DIR=str(tmp_path / "nirgendwo"))

    assert result.returncode != 0
    assert "existiert nicht" in result.stderr
    assert installation["docker_log"].exists() is False


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_an_installation_without_git_points_at_the_bootstrap_route(installation):
    _write_env(installation["target"])
    shutil.rmtree(installation["target"] / ".git")

    result = _run(installation)

    assert result.returncode != 0
    assert "bootstrap.sh" in result.stderr


@pytest.mark.skipif(os.getuid() != 0, reason="the script refuses to run as a normal user")
def test_an_installation_without_an_env_is_refused(installation):
    result = _run(installation)

    assert result.returncode != 0
    assert "install.sh" in result.stderr
    # nothing was fetched or started
    assert (installation["target"] / "version.txt").read_text(encoding="utf-8") == "v1\n"
