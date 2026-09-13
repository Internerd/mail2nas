from __future__ import annotations

import os

import pytest

from mail2nas.settings import Settings, Share
from mail2nas.shares import ShareSet


def _two_shares(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    return ShareSet(
        [Share(id="nas1", label="NAS 1", path=str(first)), Share(id="nas2", path=str(second))],
        fallback_root=str(first),
    )


# --- picking the right root --------------------------------------------------


def test_named_share_is_used(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.root_for("nas2") == tmp_path / "nas2"


def test_empty_id_means_the_default_share(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.root_for("") == tmp_path / "nas1"


def test_unknown_share_falls_back_to_the_default_instead_of_failing(tmp_path):
    """A rule may name a share that was deleted - file it, do not lose it."""
    shares = _two_shares(tmp_path)

    assert shares.root_for("geloescht") == tmp_path / "nas1"


def test_disabled_share_falls_back_to_the_default(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(first)), Share(id="nas2", path=str(second), enabled=False)],
        fallback_root=str(first),
    )

    assert shares.root_for("nas2") == first


def test_first_enabled_share_is_the_default(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(first), enabled=False), Share(id="nas2", path=str(second))],
        fallback_root=str(tmp_path),
    )

    assert shares.default().id == "nas2"


def test_without_configured_shares_the_storage_root_is_used(tmp_path):
    """Deployments that never opened the shares page keep working."""
    shares = ShareSet(None, fallback_root=str(tmp_path))

    assert shares.root_for("") == tmp_path
    assert shares.root_for("irgendwas") == tmp_path


def test_from_settings_uses_the_configured_shares(tmp_path):
    settings = Settings(shares=[Share(id="a", path=str(tmp_path / "a"))])

    assert ShareSet.from_settings(settings, tmp_path).root_for("a") == tmp_path / "a"


# --- resolving folders -------------------------------------------------------


def test_resolve_joins_below_the_share_root(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.resolve("nas2", "rechnungen/2026") == tmp_path / "nas2" / "rechnungen" / "2026"


@pytest.mark.parametrize("folder", ["../outside", "/etc", ""])
def test_resolve_refuses_to_leave_the_share(tmp_path, folder):
    shares = _two_shares(tmp_path)

    with pytest.raises(ValueError):
        shares.resolve("nas2", folder)


# --- mount checks ------------------------------------------------------------


def test_missing_mount_point_is_reported(tmp_path):
    problem = ShareSet.check_root(tmp_path / "not-mounted")

    assert "existiert nicht" in problem


def test_a_file_is_not_a_share(tmp_path):
    a_file = tmp_path / "file"
    a_file.write_text("x", encoding="utf-8")

    assert "kein Verzeichnis" in ShareSet.check_root(a_file)


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_mount_point_is_reported(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        assert "nicht beschreibbar" in ShareSet.check_root(readonly)
    finally:
        readonly.chmod(0o700)


def test_usable_share_reports_no_problem(tmp_path):
    assert ShareSet.check_root(tmp_path) is None


def test_status_flags_the_broken_share(tmp_path):
    ok = tmp_path / "nas1"
    ok.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(ok)), Share(id="nas2", path=str(tmp_path / "gone"))],
        fallback_root=str(ok),
    )

    status = {s.id: s for s in shares.status()}

    assert status["nas1"].ok is True
    assert "(Standard)" in status["nas1"].label
    assert status["nas2"].ok is False
