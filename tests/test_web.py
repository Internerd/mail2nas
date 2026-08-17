from __future__ import annotations

import re

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.mapping import Mapping, Rule, load_rules, save_rules
from mail2nas.printers import PrinterStore
from mail2nas.printing import from_config as printing_from_config
from mail2nas.runtime import Runtime
from mail2nas.state import ProcessedStore, SettingsStore
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
    accounts = AccountStore(config.state_db_path)
    mapping = Mapping(storage, config.mapping_path, config.fallback_folder)
    printers = PrinterStore(config.state_db_path)
    runtime = Runtime(
        config,
        storage,
        mapping,
        ProcessedStore(config.state_db_path),
        settings,
        accounts,
        printers=printers,
        printing=printing_from_config(config, printers),
    )
    ensure_password(settings, config.web_password)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app, storage, settings, config, runtime


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
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "Rechnung", "folder": "", "new_folder": "rechnungen",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("Rechnung", "rechnungen")
    ]


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
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    response = client.post(
        "/mapping/add",
        data={"keyword": "re", "new_folder": "woanders",
              "csrf_token": _csrf(client, "/mapping")},
        follow_redirects=True,
    )

    assert "gibt es schon" in response.get_data(as_text=True)
    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("RE", "rechnungen")
    ]


@pytest.mark.parametrize("folder", ["../ausbruch", "/etc", ""])
def test_target_folder_cannot_escape_the_archive_root(client, env, folder, tmp_path):
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": folder,
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == []
    assert not (tmp_path.parent / "ausbruch").exists()


def test_changing_the_folder_of_an_existing_rule(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post(
        "/mapping/update",
        data={"index": "0", "folder": "belege", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("RE", "belege")
    ]


def test_deleting_a_rule_keeps_the_others(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    client.post(
        "/mapping/delete",
        data={"index": "0", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [r.keyword for r in load_rules(storage, config.mapping_path)] == ["LS"]


def test_unreadable_share_does_not_break_the_page(client, env, monkeypatch):
    """A NAS that is briefly away must still render, with an explanation."""
    _, storage, _, _, runtime = env
    _login(client)
    monkeypatch.setattr(
        storage, "list_folders", lambda *a, **k: (_ for _ in ()).throw(OSError("NAS weg"))
    )

    response = client.get("/mapping")

    assert response.status_code == 200
    assert "NAS weg" in response.get_data(as_text=True)


# --- password handling ----------------------------------------------------------


def test_password_can_be_changed_and_the_old_one_stops_working(client, env):
    _, _, settings, _, runtime = env
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
    _, _, settings, _, runtime = env
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
    _, _, settings, _, runtime = env
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
    app = env[0]
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
    _, _, settings, _, runtime = env

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
    _, _, settings, _, runtime = env
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


# --- rule order ------------------------------------------------------------------


def _keywords(storage, config):
    return [rule.keyword for rule in load_rules(storage, config.mapping_path)]


def test_moving_a_rule_up_reorders_the_file(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path,
               [Rule.create("A", "a"), Rule.create("B", "b"), Rule.create("C", "c")])
    _login(client)

    client.post("/mapping/up", data={"index": "2", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "C", "B"]


def test_moving_a_rule_down_reorders_the_file(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/down", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["B", "A"]


def test_moving_the_top_rule_up_is_harmless(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/up", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "B"]


@pytest.mark.parametrize("index", ["7", "-1", "keineZahl"])
def test_a_bogus_row_index_is_refused(client, env, index):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/delete", data={"index": index, "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A"]


def test_new_rules_are_appended_at_the_bottom(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/add", data={"keyword": "B", "new_folder": "b",
                                      "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "B"]


# --- accounts ---------------------------------------------------------------------


def _add_account(runtime, **fields):
    defaults = dict(name="Buchhaltung", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_config_page_lists_the_accounts(client, env):
    _, _, _, _, runtime = env
    _add_account(runtime)
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buchhaltung" in html
    assert "imap.example.com" in html


def test_creating_an_account_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/accounts/new", data={
        "name": "Zweitpostfach", "host": "imap2.example.com", "port": "143",
        "user": "zwei", "password": "geheim", "folder": "INBOX", "mode": "poll",
        "processed_folder": "", "oversized_folder": "", "enabled": "1",
        "csrf_token": _csrf(client, "/config/accounts/new")})

    accounts = runtime.accounts.all()
    assert [a.name for a in accounts] == ["Zweitpostfach"]
    assert accounts[0].port == 143 and accounts[0].ssl is False


def test_editing_an_account_keeps_the_password_when_left_empty(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="altesGeheim")
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Neuer Name", "host": "imap.example.com", "port": "993",
        "user": "u", "password": "", "folder": "INBOX", "mode": "idle",
        "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.password == "altesGeheim"
    assert account.name == "Neuer Name" and account.mode == "idle"


def test_an_invalid_port_is_rejected(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "A", "host": "h", "port": "keinPort", "user": "u", "password": "",
        "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")},
        follow_redirects=True)

    assert "Port" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).host == "imap.example.com"


def test_deleting_an_account(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.accounts.all() == []


def test_a_rule_can_be_bound_to_an_account(client, env):
    _, storage, _, config, runtime = env
    account_id = _add_account(runtime)
    _add_account(runtime, name="Zweites")
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": str(account_id),
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path)[0].account == str(account_id)


def test_a_rule_cannot_reference_an_unknown_account(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path) == []


# --- moving the mapping file --------------------------------------------------------


def test_moving_the_mapping_file_takes_the_rules_along(client, env, tmp_path):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "config/regeln.yaml", "csrf_token": _csrf(client, "/config")})

    assert runtime.mapping_path == "config/regeln.yaml"
    assert [r.keyword for r in load_rules(storage, "config/regeln.yaml")] == ["RE"]
    assert not (tmp_path / "mapping.yaml").exists()


def test_the_mapping_path_cannot_escape_the_archive_root(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "../woanders.yaml", "csrf_token": _csrf(client, "/config")})

    assert runtime.mapping_path == "mapping.yaml"


def test_moving_to_the_same_path_is_a_no_op(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "mapping.yaml", "csrf_token": _csrf(client, "/config")})

    assert [r.keyword for r in load_rules(storage, "mapping.yaml")] == ["RE"]


def test_reordering_without_a_csrf_token_is_refused(client, env):
    """The arrows go through a helper, so their CSRF check needs its own test."""
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    response = client.post("/mapping/up", data={"index": "1"})

    assert response.status_code == 400
    assert _keywords(storage, config) == ["A", "B"]


def test_the_stored_account_password_is_never_sent_to_the_browser(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="streng-geheim")
    _login(client)

    html = client.get(f"/config/accounts/{account_id}").get_data(as_text=True)

    assert "streng-geheim" not in html


# --- printers -----------------------------------------------------------------------


def _add_printer(runtime, **fields):
    defaults = dict(name="Buero EG", destination="Kyocera_M2540")
    defaults.update(fields)
    return runtime.printers.add(**defaults)


def test_config_page_lists_the_printers(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime, server="cups.lan:631")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buero EG" in html
    assert "Kyocera_M2540" in html
    assert "cups.lan:631" in html


def test_creating_a_printer_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/printers/new", data={
        "name": "Buchhaltung", "destination": "HP_LJ", "server": "", "copies": "2",
        "options": "media=A4 sides=two-sided-long-edge", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")})

    printers = runtime.printers.all()
    assert [(p.name, p.destination, p.copies) for p in printers] == [("Buchhaltung", "HP_LJ", 2)]
    assert printers[0].option_list == ["media=A4", "sides=two-sided-long-edge"]


def test_an_unusable_queue_name_is_rejected_with_a_message(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/printers/new", data={
        "name": "Kaputt", "destination": "zwei woerter", "copies": "1", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")}, follow_redirects=True)

    assert "Leerzeichen" in response.get_data(as_text=True)
    assert runtime.printers.all() == []


def test_editing_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}", data={
        "name": "Buero OG", "destination": "Kyocera_M2540", "copies": "1", "enabled": "",
        "csrf_token": _csrf(client, f"/config/printers/{printer_id}")})

    printer = runtime.printers.get(printer_id)
    assert printer.name == "Buero OG"
    assert printer.enabled is False


def test_deleting_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.printers.all() == []


def test_a_test_print_reports_a_failing_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **k: subprocess.CompletedProcess([], 1, "", "lp: Kein Drucker"),
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testdruck fehlgeschlagen" in response.get_data(as_text=True)


def test_a_test_print_confirms_a_working_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess, "run", lambda *a, **k: subprocess.CompletedProcess([], 0, "request id is q-1", "")
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testseite" in response.get_data(as_text=True)


def test_the_print_settings_of_a_mailbox_are_saved(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.print_attachments is True
    assert account.printer == str(printer_id)
    # the "archive" box was not ticked, so this mailbox prints only
    assert account.archive_attachments is False


def test_a_mailbox_cannot_reference_an_unknown_printer(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": "999",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "Drucker" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).print_attachments is False


def test_a_rule_can_be_set_to_print_on_a_specific_printer(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is True
    assert rule.printer == str(printer_id)


def test_a_rule_can_print_on_the_mailbox_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "account",
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is True
    assert rule.printer == ""


def test_a_rule_cannot_reference_an_unknown_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path) == []


def test_changing_a_rules_folder_keeps_its_print_settings(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "belege", "print_fields": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.folder == "belege"
    assert (rule.print_attachments, rule.printer) == (True, str(printer_id))


def test_printing_can_be_switched_off_for_a_rule(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "rechnungen", "print_fields": "1", "printer": "",
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is False
    assert rule.printer == ""


def test_without_a_printer_the_print_controls_stay_hidden(client, env):
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "nicht drucken" not in html
