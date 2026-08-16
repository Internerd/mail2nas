from __future__ import annotations

import re

import pytest

from mail2nas.mapping import load_rules, save_rules
from mail2nas.state import SettingsStore
from mail2nas.storage import LocalStorage
from mail2nas.web import (
    SETTING_PASSWORD_HASH,
    LoginThrottle,
    create_app,
    ensure_password,
)
from tests.test_archiver import _make_config

PASSWORD = "geheim1234"


@pytest.fixture
def env(tmp_path):
    """A configured app plus the storage and settings behind it."""
    config = _make_config(tmp_path, web_enabled=True, web_password=PASSWORD)
    storage = LocalStorage(config.storage_root)
    settings = SettingsStore(config.state_db_path)
    ensure_password(settings, config.web_password)
    app = create_app(config, storage, settings)
    app.config.update(TESTING=True)
    return app, storage, settings, config


@pytest.fixture
def client(env):
    app = env[0]
    with app.test_client() as client:
        yield client


def _csrf(client, path="/login") -> str:
    """Fetch a page and pull the CSRF token out of it, like a browser would."""
    html = client.get(path).get_data(as_text=True)
    match = re.search(r'name="csrf_token" value="([^"]+)"', html)
    assert match, f"no CSRF token on {path}"
    return match.group(1)


def _login(client, password=PASSWORD):
    return client.post(
        "/login",
        data={"password": password, "csrf_token": _csrf(client)},
        follow_redirects=False,
    )


# --- authentication -----------------------------------------------------------


def test_mapping_page_requires_login(client):
    response = client.get("/mapping")

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_login_with_correct_password_reaches_the_mapping_page(client):
    assert _login(client).status_code == 302

    page = client.get("/mapping")
    assert page.status_code == 200
    assert "Zuordnungen" in page.get_data(as_text=True)


def test_login_with_wrong_password_is_rejected(client):
    response = client.post(
        "/login", data={"password": "falsch", "csrf_token": _csrf(client)}
    )

    assert response.status_code == 401
    assert client.get("/mapping").status_code == 302


def test_post_without_csrf_token_is_refused(client):
    _login(client)

    response = client.post("/mapping/add", data={"keyword": "RE", "folder": "rechnungen"})

    assert response.status_code == 400


def test_logout_ends_the_session(client):
    _login(client)
    token = _csrf(client, "/mapping")

    client.post("/logout", data={"csrf_token": token})

    assert client.get("/mapping").status_code == 302


def test_healthz_needs_no_login(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_data(as_text=True).strip() == "ok"


def test_security_headers_are_set(client):
    headers = client.get("/login").headers

    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert headers["X-Frame-Options"] == "DENY"


# --- editing the mapping -------------------------------------------------------


def test_adding_a_rule_writes_it_to_the_share(client, env):
    _, storage, _, config = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "Rechnung", "folder": "", "new_folder": "rechnungen",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == {"Rechnung": "rechnungen"}


def test_a_new_folder_is_created_on_the_share(client, env, tmp_path):
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": "rechnungen/2026",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert (tmp_path / "rechnungen" / "2026").is_dir()


def test_existing_folders_are_offered_for_selection(client, tmp_path):
    (tmp_path / "lieferscheine").mkdir()
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert '<option value="lieferscheine">' in html


def test_duplicate_keyword_is_rejected_case_insensitively(client, env):
    _, storage, _, config = env
    save_rules(storage, config.mapping_path, {"RE": "rechnungen"})
    _login(client)

    response = client.post(
        "/mapping/add",
        data={"keyword": "re", "new_folder": "woanders",
              "csrf_token": _csrf(client, "/mapping")},
        follow_redirects=True,
    )

    assert "gibt es schon" in response.get_data(as_text=True)
    assert load_rules(storage, config.mapping_path) == {"RE": "rechnungen"}


@pytest.mark.parametrize("folder", ["../ausbruch", "/etc", ""])
def test_target_folder_cannot_escape_the_archive_root(client, env, folder, tmp_path):
    _, storage, _, config = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": folder,
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == {}
    assert not (tmp_path.parent / "ausbruch").exists()


def test_changing_the_folder_of_an_existing_rule(client, env):
    _, storage, _, config = env
    save_rules(storage, config.mapping_path, {"RE": "rechnungen"})
    _login(client)

    client.post(
        "/mapping/update",
        data={"keyword": "RE", "folder": "belege", "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == {"RE": "belege"}


def test_deleting_a_rule_keeps_the_others(client, env):
    _, storage, _, config = env
    save_rules(storage, config.mapping_path, {"RE": "rechnungen", "LS": "lieferscheine"})
    _login(client)

    client.post(
        "/mapping/delete",
        data={"keyword": "RE", "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == {"LS": "lieferscheine"}


def test_unreadable_share_does_not_break_the_page(client, env, monkeypatch):
    """A NAS that is briefly away must still render, with an explanation."""
    _, storage, _, _ = env
    _login(client)
    monkeypatch.setattr(
        storage, "list_folders", lambda *a, **k: (_ for _ in ()).throw(OSError("NAS weg"))
    )

    response = client.get("/mapping")

    assert response.status_code == 200
    assert "NAS weg" in response.get_data(as_text=True)


# --- password handling ----------------------------------------------------------


def test_password_can_be_changed_and_the_old_one_stops_working(client, env):
    _, _, settings, _ = env
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert "Passwort geaendert" in response.get_data(as_text=True)
    client.post("/logout", data={"csrf_token": _csrf(client, "/mapping")})
    assert _login(client, PASSWORD).status_code == 401
    assert _login(client, "neuesGeheim1").status_code == 302


def test_wrong_current_password_does_not_change_anything(client, env):
    _, _, settings, _ = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    client.post(
        "/password",
        data={"current": "falsch", "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
    )

    assert settings.get(SETTING_PASSWORD_HASH) == before


@pytest.mark.parametrize(
    "new,confirm,expected",
    [("kurz", "kurz", "mindestens"), ("langgenug1", "andersrum", "ueberein")],
)
def test_weak_or_mistyped_new_password_is_rejected(client, env, new, confirm, expected):
    _, _, settings, _ = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": new, "confirm": confirm,
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert expected in response.get_data(as_text=True)
    assert settings.get(SETTING_PASSWORD_HASH) == before


def test_changing_the_password_logs_other_sessions_out(env):
    """A stolen session cookie must not survive a password change."""
    app, _, _, _ = env
    # Two plain clients rather than nested `with` blocks: overlapping request
    # contexts confuse Flask's teardown, and no session inspection is needed.
    first, second = app.test_client(), app.test_client()
    _login(first)
    _login(second)
    assert second.get("/mapping").status_code == 200

    first.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(first, "/password")},
    )

    assert second.get("/mapping").status_code == 302
    assert first.get("/mapping").status_code == 200


def test_password_is_not_stored_in_clear_text(env):
    _, _, settings, _ = env

    stored = settings.get(SETTING_PASSWORD_HASH)

    assert PASSWORD not in stored
    assert stored.startswith("scrypt:") or stored.startswith("pbkdf2:")


def test_enabling_the_ui_without_a_password_fails_fast(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    with pytest.raises(SystemExit, match="WEB_PASSWORD"):
        ensure_password(settings, "")


def test_too_short_initial_password_fails_fast(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    with pytest.raises(SystemExit, match="at least"):
        ensure_password(settings, "kurz")


def test_stored_password_wins_over_the_configured_one(env):
    """WEB_PASSWORD is the initial value only - a later change must survive restarts."""
    _, _, settings, _ = env
    settings.set(SETTING_PASSWORD_HASH, "scrypt:already-set")

    ensure_password(settings, "eineAndere123")

    assert settings.get(SETTING_PASSWORD_HASH) == "scrypt:already-set"


# --- login throttling -------------------------------------------------------------


def test_throttle_blocks_after_repeated_failures():
    throttle = LoginThrottle(max_failures=3, lockout=60)

    for _ in range(2):
        throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") == 0

    throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") > 0
    assert throttle.seconds_blocked("10.0.0.2") == 0


def test_successful_login_clears_the_throttle():
    throttle = LoginThrottle(max_failures=1, lockout=60)
    throttle.record_failure("10.0.0.1")

    throttle.reset("10.0.0.1")

    assert throttle.seconds_blocked("10.0.0.1") == 0


def test_locked_out_client_is_refused_even_with_the_right_password(client, env):
    for _ in range(6):
        client.post("/login", data={"password": "falsch", "csrf_token": _csrf(client)})

    response = client.post(
        "/login", data={"password": PASSWORD, "csrf_token": _csrf(client)}
    )

    assert response.status_code == 429
    assert client.get("/mapping").status_code == 302
