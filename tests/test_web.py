from __future__ import annotations

import re

import pytest

from mail2nas.mapping import Rule
from mail2nas.state import SettingsStore
from mail2nas.web import (
    SETTING_PASSWORD_HASH,
    LoginThrottle,
    create_app,
    ensure_password,
)
from tests.test_archiver import _make_runtime

PASSWORD = "geheim1234"


@pytest.fixture
def env(tmp_path):
    """A configured app plus the storage and settings behind it.

    tmp_path is the (local) default archive, as the UI would set it up.
    """
    runtime = _make_runtime(tmp_path, web_password=PASSWORD)
    settings, config = runtime.settings, runtime.config
    ensure_password(settings, config.web_password)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app, runtime.storage, settings, config, runtime


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

    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
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
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    response = client.post(
        "/mapping/add",
        data={"keyword": "re", "new_folder": "woanders",
              "csrf_token": _csrf(client, "/mapping")},
        follow_redirects=True,
    )

    assert "gibt es schon" in response.get_data(as_text=True)
    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
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

    assert runtime.rule_store.load() == []
    assert not (tmp_path.parent / "ausbruch").exists()


def test_changing_the_folder_of_an_existing_rule(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    client.post(
        "/mapping/update",
        data={"index": "0", "folder": "belege", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in runtime.rule_store.load()] == [
        ("RE", "belege")
    ]


def test_deleting_a_rule_keeps_the_others(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    client.post(
        "/mapping/delete",
        data={"index": "0", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [r.keyword for r in runtime.rule_store.load()] == ["LS"]


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


def _keywords(runtime):
    return [rule.keyword for rule in runtime.rule_store.load()]


def test_moving_a_rule_up_reorders_the_file(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b"), Rule.create("C", "c")])
    _login(client)

    client.post("/mapping/up", data={"index": "2", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "C", "B"]


def test_moving_a_rule_down_reorders_the_file(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/down", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["B", "A"]


def test_moving_the_top_rule_up_is_harmless(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/up", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "B"]


@pytest.mark.parametrize("index", ["7", "-1", "keineZahl"])
def test_a_bogus_row_index_is_refused(client, env, index):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/delete", data={"index": index, "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A"]


def test_new_rules_are_appended_at_the_bottom(client, env):
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/add", data={"keyword": "B", "new_folder": "b",
                                      "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(runtime) == ["A", "B"]


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

    assert runtime.rule_store.load()[0].account == str(account_id)


def test_a_rule_cannot_reference_an_unknown_account(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert runtime.rule_store.load() == []


# --- moving the mapping file --------------------------------------------------------


def test_reordering_without_a_csrf_token_is_refused(client, env):
    """The arrows go through a helper, so their CSRF check needs its own test."""
    _, storage, _, config, runtime = env
    runtime.mapping.save([Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    response = client.post("/mapping/up", data={"index": "1"})

    assert response.status_code == 400
    assert _keywords(runtime) == ["A", "B"]


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

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is True
    assert rule.printer == str(printer_id)


def test_a_rule_can_print_on_the_mailbox_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "account",
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is True
    assert rule.printer == ""


def test_a_rule_cannot_reference_an_unknown_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert runtime.rule_store.load() == []


def test_changing_a_rules_folder_keeps_its_print_settings(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    runtime.mapping.save([Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "belege", "print_fields": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.folder == "belege"
    assert (rule.print_attachments, rule.printer) == (True, str(printer_id))


def test_printing_can_be_switched_off_for_a_rule(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    runtime.mapping.save([Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "rechnungen", "print_fields": "1", "printer": "",
        "csrf_token": _csrf(client, "/mapping")})

    rule = runtime.rule_store.load()[0]
    assert rule.print_attachments is False
    assert rule.printer == ""


def test_without_a_printer_the_print_controls_stay_hidden(client, env):
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "nicht drucken" not in html


# --- delivery addresses ------------------------------------------------------


def _add_address(runtime, **fields) -> int:
    values = dict(
        name="Drucker Buero",
        recipient="drucker@firma.de",
        print_attachments=True,
        archive_attachments=True,
    )
    values.update(fields)
    return runtime.addresses.add(**values)


@pytest.mark.parametrize("path", ["/config/addresses/new", "/config/addresses/1"])
def test_address_pages_require_login(client, path):
    response = client.get(path)

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_config_page_lists_the_addresses(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _add_address(runtime, printer=str(printer_id), folder="ausdrucke")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "drucker@firma.de" in html
    assert "ausdrucke" in html
    # the printer is named by its label, not by its bare id
    assert "Buero EG" in html


def test_creating_an_address_through_the_form(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post("/config/addresses/new", data={
        "name": "Drucker Buero", "recipient": "drucker@firma.de", "sender": "@firma.de",
        "print_attachments": "1", "printer": str(printer_id),
        "archive_attachments": "1", "folder": "ausdrucke", "enabled": "1",
        "csrf_token": _csrf(client, "/config/addresses/new")})

    rules = runtime.addresses.all()
    assert [(r.recipient, r.sender, r.printer, r.folder) for r in rules] == [
        ("drucker@firma.de", "@firma.de", str(printer_id), "ausdrucke")
    ]


def test_an_address_without_an_at_sign_is_rejected_with_a_message(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Kaputt", "recipient": "kein-at-zeichen", "print_attachments": "1",
        "archive_attachments": "1", "csrf_token": _csrf(client, "/config/addresses/new")},
        follow_redirects=True)

    assert "@" in response.get_data(as_text=True)
    assert runtime.addresses.all() == []


def test_an_address_that_neither_prints_nor_files_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Weg damit", "recipient": "drucker@firma.de",
        "csrf_token": _csrf(client, "/config/addresses/new")}, follow_redirects=True)

    assert "verworfen" in response.get_data(as_text=True)
    assert runtime.addresses.all() == []


def test_editing_an_address(client, env):
    _, _, _, _, runtime = env
    address_id = _add_address(runtime)
    _login(client)

    client.post(f"/config/addresses/{address_id}", data={
        "name": "Drucker OG", "recipient": "drucker-og@firma.de", "sender": "",
        "print_attachments": "1", "printer": "", "archive_attachments": "1",
        "folder": "", "enabled": "",
        "csrf_token": _csrf(client, f"/config/addresses/{address_id}")})

    rule = runtime.addresses.get(address_id)
    assert (rule.name, rule.recipient, rule.enabled) == ("Drucker OG", "drucker-og@firma.de", False)


def test_deleting_an_address(client, env):
    _, _, _, _, runtime = env
    address_id = _add_address(runtime)
    _login(client)

    client.post(f"/config/addresses/{address_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.addresses.all() == []


def test_opening_a_deleted_address_does_not_500(client, env):
    _login(client)

    response = client.get("/config/addresses/999", follow_redirects=True)

    assert response.status_code == 200
    assert "gibt es nicht mehr" in response.get_data(as_text=True)


def test_deleting_a_printer_unpins_the_addresses_using_it(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    address_id = _add_address(runtime, printer=str(printer_id))
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.addresses.get(address_id).printer == ""


def test_changes_to_addresses_need_a_csrf_token(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/addresses/new", data={
        "name": "Ohne Token", "recipient": "drucker@firma.de", "print_attachments": "1"})

    assert response.status_code == 400
    assert runtime.addresses.all() == []


# --- finding printers on the network -----------------------------------------


def test_the_discovery_page_needs_login(client):
    response = client.get("/config/printers/discover")

    assert response.status_code == 302


def test_the_discovery_page_offers_the_configured_cups_server(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime, server="cups.lan:631")
    _login(client)

    html = client.get("/config/printers/discover").get_data(as_text=True)

    assert 'value="cups.lan:631"' in html


def test_searching_lists_what_was_found(client, env, monkeypatch):
    from mail2nas import web as web_module
    from mail2nas.discovery import Found

    monkeypatch.setattr(
        web_module,
        "discover",
        lambda server, **kwargs: (
            [
                Found("Buero_MFP", "Buero_MFP", "cups.lan", "cups", "ipp://10.0.0.5/ipp/print"),
                Found("Kyocera M2540", "ipp/print", "10.0.0.6", "mdns", "ipp://10.0.0.6/ipp/print"),
            ],
            [],
        ),
    )
    _login(client)

    html = client.post(
        "/config/printers/discover",
        data={"server": "cups.lan", "csrf_token": _csrf(client, "/config/printers/discover")},
    ).get_data(as_text=True)

    assert "Buero_MFP" in html
    assert "Kyocera M2540" in html
    # the device without a queue comes with the command that creates one
    assert "lpadmin -p Kyocera_M2540" in html


def test_a_failing_search_reports_instead_of_crashing(client, env, monkeypatch):
    from mail2nas import web as web_module

    def boom(*args, **kwargs):
        raise OSError("kaputt")

    monkeypatch.setattr(web_module, "discover", boom)
    _login(client)

    response = client.post(
        "/config/printers/discover",
        data={"csrf_token": _csrf(client, "/config/printers/discover")},
    )

    assert response.status_code == 200
    assert "kaputt" in response.get_data(as_text=True)


def test_taking_over_a_found_printer_prefills_the_form(client, env):
    _login(client)

    html = client.get(
        "/config/printers/new?name=Kyocera&destination=ipp%2Fprint&server=10.0.0.6"
    ).get_data(as_text=True)

    assert 'value="Kyocera"' in html
    assert 'value="ipp/print"' in html
    assert 'value="10.0.0.6"' in html
    # nothing is stored yet, so there is nothing to test-print or delete
    assert "Testseite drucken" not in html


# --- archives -----------------------------------------------------------------


def _add_archive(runtime, **fields) -> int:
    values = dict(name="NAS 2", backend="local", path="/mnt/nas2")
    values.update(fields)
    return runtime.archives.add(**values)


@pytest.mark.parametrize("path", ["/config/archives/new", "/config/archives/1"])
def test_archive_pages_require_login(client, path):
    assert client.get(path).status_code == 302


def test_config_page_lists_the_archives(client, env):
    _, _, _, _, runtime = env
    _add_archive(runtime, name="NAS Buero", backend="smb", host="nas.lan", share="Belege",
                 user="u", password="p")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "NAS Buero" in html
    assert "//nas.lan/Belege" in html


def test_creating_an_archive_through_the_form(client, env, tmp_path):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/archives/new", data={
        "name": "NAS 2", "backend": "local", "path": str(tmp_path / "zwei"), "enabled": "1",
        "csrf_token": _csrf(client, "/config/archives/new")})

    assert [(a.name, a.path) for a in runtime.archives.all()][1:] == [
        ("NAS 2", str(tmp_path / "zwei"))
    ]


def test_an_smb_archive_without_credentials_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/archives/new", data={
        "name": "Kaputt", "backend": "smb", "host": "nas.lan", "share": "Belege",
        "csrf_token": _csrf(client, "/config/archives/new")}, follow_redirects=True)

    assert "Benutzer" in response.get_data(as_text=True)
    assert [a.name for a in runtime.archives.all()] == ["Test"]


def test_editing_an_archive_keeps_the_password_when_left_empty(client, env):
    _, _, _, _, runtime = env
    archive_id = _add_archive(runtime, backend="smb", host="nas.lan", share="Belege",
                              user="u", password="geheim", path="")
    _login(client)

    client.post(f"/config/archives/{archive_id}", data={
        "name": "NAS umbenannt", "backend": "smb", "host": "nas.lan", "share": "Belege",
        "user": "u", "password": "", "port": "445", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/archives/{archive_id}")})

    archive = runtime.archives.get(archive_id)
    assert (archive.name, archive.password) == ("NAS umbenannt", "geheim")


def test_testing_an_archive_reports_success(client, env, tmp_path):
    _, _, _, _, runtime = env
    target = tmp_path / "erreichbar"
    target.mkdir()
    archive_id = _add_archive(runtime, path=str(target))
    _login(client)

    response = client.post(f"/config/archives/{archive_id}/test", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert "erreichbar und beschreibbar" in response.get_data(as_text=True)


def test_testing_an_unreachable_archive_reports_the_reason(client, env, tmp_path):
    _, _, _, _, runtime = env
    archive_id = _add_archive(runtime, path=str(tmp_path / "nicht-gemountet"))
    _login(client)

    response = client.post(f"/config/archives/{archive_id}/test", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert "Nicht erreichbar" in response.get_data(as_text=True)


def test_the_last_archive_cannot_be_deleted(client, env):
    _, _, _, _, runtime = env
    archive_id = runtime.archives.all()[0].id
    _login(client)

    client.post(f"/config/archives/{archive_id}/delete", data={
        "csrf_token": _csrf(client, "/config")}, follow_redirects=True)

    assert len(runtime.archives.all()) == 1


def test_deleting_an_archive(client, env):
    _, _, _, _, runtime = env
    _add_archive(runtime, name="Haupt")
    second = _add_archive(runtime, name="NAS 2")
    _login(client)

    client.post(f"/config/archives/{second}/delete", data={"csrf_token": _csrf(client, "/config")})

    assert [a.name for a in runtime.archives.all()] == ["Test", "Haupt"]


def test_a_rule_can_name_an_archive(client, env, tmp_path):
    _, storage, _, config, runtime = env
    _add_archive(runtime, name="Haupt", path=str(tmp_path))
    second = _add_archive(runtime, name="NAS 2", path=str(tmp_path / "zwei"))
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Vertrag", "folder": "", "new_folder": "vertraege", "archive": str(second),
        "csrf_token": _csrf(client, "/mapping")})

    rules = runtime.rule_store.load()
    assert [(r.keyword, r.archive) for r in rules] == [("Vertrag", str(second))]


def test_a_rule_cannot_name_an_archive_that_does_not_exist(client, env, config=None):
    _, storage, _, config, runtime = env
    _add_archive(runtime)
    _login(client)

    response = client.post("/mapping/add", data={
        "keyword": "Vertrag", "folder": "", "new_folder": "vertraege", "archive": "999",
        "csrf_token": _csrf(client, "/mapping")}, follow_redirects=True)

    assert "Archiv" in response.get_data(as_text=True)
    assert runtime.rule_store.load() == []


# --- pickup folders ------------------------------------------------------------


def test_creating_a_pickup_folder(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/pickups/new", data={
        "name": "Kopierer Flur", "folder": "scans/flur", "target_folder": "eingang",
        "enabled": "1", "csrf_token": _csrf(client, "/config/pickups/new")})

    pickups = runtime.pickups.all()
    assert [(p.name, p.folder, p.target_folder) for p in pickups] == [
        ("Kopierer Flur", "scans/flur", "eingang")
    ]


def test_a_pickup_target_inside_its_own_folder_is_rejected(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/pickups/new", data={
        "name": "Schleife", "folder": "scans", "target_folder": "scans/fertig",
        "enabled": "1", "csrf_token": _csrf(client, "/config/pickups/new")},
        follow_redirects=True)

    assert "immer wieder eingelesen" in response.get_data(as_text=True)
    assert runtime.pickups.all() == []


def test_config_page_lists_the_pickup_folders(client, env):
    _, _, _, _, runtime = env
    runtime.pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Kopierer" in html
    assert "scans" in html


def test_editing_and_deleting_a_pickup_folder(client, env):
    _, _, _, _, runtime = env
    pickup_id = runtime.pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _login(client)

    client.post(f"/config/pickups/{pickup_id}", data={
        "name": "Kopierer OG", "folder": "scans", "target_folder": "eingang", "enabled": "",
        "csrf_token": _csrf(client, f"/config/pickups/{pickup_id}")})
    assert runtime.pickups.get(pickup_id).enabled is False

    client.post(f"/config/pickups/{pickup_id}/delete", data={"csrf_token": _csrf(client, "/config")})
    assert runtime.pickups.all() == []


def test_deleting_a_printer_stops_the_pickups_printing(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    pickup_id = runtime.pickups.add(
        name="Kopierer", folder="scans", print_attachments=True, printer=str(printer_id)
    )
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete", data={"csrf_token": _csrf(client, "/config")})

    pickup = runtime.pickups.get(pickup_id)
    assert (pickup.print_attachments, pickup.printer) == (False, "")


# --- quarantine list and pickup timing ------------------------------------------




# --- the first password is generated, not required -------------------------------


def test_without_any_password_a_random_one_is_generated(tmp_path):
    from mail2nas.web import read_initial_password

    settings = SettingsStore(str(tmp_path / "state.db"))

    generated = ensure_password(settings, "", str(tmp_path))

    assert generated and len(generated) >= 16
    assert read_initial_password(str(tmp_path)) == generated
    assert oct((tmp_path / "initial-password.txt").stat().st_mode & 0o777) == "0o600"
    assert settings.get(SETTING_PASSWORD_HASH)


def test_a_too_short_old_password_is_replaced_by_a_random_one(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    assert ensure_password(settings, "kurz", str(tmp_path)) is not None


def test_changing_the_password_removes_the_generated_one(tmp_path):
    from mail2nas.web import read_initial_password

    runtime = _make_runtime(tmp_path)
    generated = ensure_password(runtime.settings, "", runtime.config.data_dir)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    with app.test_client() as client:
        _login(client, generated)
        client.post("/password", data={
            "current": generated, "new": "meinEigenes1", "confirm": "meinEigenes1",
            "csrf_token": _csrf(client, "/password")})

    assert read_initial_password(runtime.config.data_dir) is None


# --- overview and first-time setup ----------------------------------------------


def _fresh_client(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    ensure_password(runtime.settings, PASSWORD)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app.test_client(), runtime


def test_after_login_the_overview_is_shown(client):
    response = _login(client)

    assert response.headers["Location"].endswith("/overview")


def test_a_fresh_installation_is_walked_through_the_setup(tmp_path):
    client, _ = _fresh_client(tmp_path)
    _login(client)

    html = client.get("/overview").get_data(as_text=True)

    assert "Einrichtung" in html
    assert "Archiv einrichten" in html
    assert "Postfach anlegen" in html


def test_every_page_says_that_no_archive_exists_yet(tmp_path):
    client, _ = _fresh_client(tmp_path)
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "Noch kein Archiv eingerichtet" in html


def test_the_overview_shows_the_archive_status(client, env):
    _, _, _, _, runtime = env
    runtime.status.archive.ok = False
    runtime.status.archive.detail = "Zugriff verweigert"
    _login(client)

    html = client.get("/overview").get_data(as_text=True)

    assert "Zugriff verweigert" in html
    assert "nicht bereit" in html


def test_a_rule_can_be_added_before_any_archive_exists(tmp_path):
    """The folder is created with the first attachment; the rule must not be lost."""
    client, runtime = _fresh_client(tmp_path)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen",
        "csrf_token": _csrf(client, "/mapping")})

    assert [r.keyword for r in runtime.rule_store.load()] == ["Rechnung"]


# --- the settings page --------------------------------------------------------------


def _settings_form(**overrides):
    form = {
        "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
        "filename_prefix": "date_sender", "poll_interval": "300",
        "max_attachment_size_mb": "25", "max_message_size_mb": "50",
        "max_attachments_per_message": "20", "blocked_extensions": "exe, js",
        "pickup_min_age": "20", "printing_enabled": "1", "print_timeout": "120",
        "printable_extensions": "pdf",
    }
    form.update(overrides)
    return form


def test_the_settings_are_saved_and_take_effect_at_once(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/settings", data={
        **_settings_form(fallback_folder="sonstiges", poll_interval="60", match_body="1",
                         blocked_extensions=".EXE, bat; com"),
        "csrf_token": _csrf(client, "/settings")})

    options = runtime.options
    assert options.fallback_folder == "sonstiges"
    assert options.poll_interval == 60
    assert options.match_body is True
    assert options.blocked_extensions == {"exe", "bat", "com"}
    assert runtime.mapping.resolve("Newsletter")[0] == "sonstiges"


def test_settings_survive_a_restart(client, env, tmp_path):
    _, _, _, _, runtime = env
    _login(client)
    client.post("/settings", data={
        **_settings_form(quarantine_folder="gesperrt"), "csrf_token": _csrf(client, "/settings")})

    from mail2nas.options import OptionsStore

    assert OptionsStore(SettingsStore(str(tmp_path / "state.db"))).load().quarantine_folder == "gesperrt"


@pytest.mark.parametrize(
    "field,value,message",
    [
        ("poll_interval", "sofort", "ganze Zahl"),
        ("poll_interval", "1", "zwischen"),
        ("fallback_folder", "../ausbruch", "Ordner"),
        ("quarantine_folder", "unsorted", "verschieden"),
    ],
)
def test_unusable_settings_are_refused_and_nothing_changes(client, env, field, value, message):
    _, _, _, _, runtime = env
    before = runtime.options
    _login(client)

    response = client.post("/settings", data={
        **_settings_form(**{field: value}), "csrf_token": _csrf(client, "/settings")},
        follow_redirects=True)

    assert message in response.get_data(as_text=True)
    assert runtime.options == before


def test_emptying_the_quarantine_list_warns(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/settings", data={
        **_settings_form(blocked_extensions=""), "csrf_token": _csrf(client, "/settings")},
        follow_redirects=True)

    assert "Achtung" in response.get_data(as_text=True)
    assert runtime.blocked_extensions == frozenset()


def test_settings_changes_need_a_csrf_token(client):
    _login(client)

    assert client.post("/settings", data=_settings_form()).status_code == 400


# --- export and import of the rules ---------------------------------------------


def test_the_rules_can_be_exported(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    response = client.get("/mapping/export")

    assert response.headers["Content-Disposition"].startswith("attachment")
    assert "keyword: RE" in response.get_data(as_text=True)


def _upload(client, text, mode="append"):
    import io

    return client.post("/mapping/import", data={
        "mode": mode, "csrf_token": _csrf(client, "/mapping"),
        "rules_file": (io.BytesIO(text.encode("utf-8")), "mapping.yaml"),
    }, content_type="multipart/form-data", follow_redirects=True)


def test_an_old_mapping_file_can_be_imported(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("RE", "rechnungen")])
    _login(client)

    response = _upload(client, "re: doppelt\nLieferschein: lieferscheine\n")

    assert [r.keyword for r in runtime.rule_store.load()] == ["RE", "Lieferschein"]
    assert "uebersprungen" in response.get_data(as_text=True)


def test_importing_can_replace_the_rules(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("ALT", "alt")])
    _login(client)

    _upload(client, "NEU: neu\n", mode="replace")

    assert [r.keyword for r in runtime.rule_store.load()] == ["NEU"]


def test_an_import_with_an_unsafe_folder_changes_nothing(client, env):
    _, _, _, _, runtime = env
    runtime.mapping.save([Rule.create("ALT", "alt")])
    _login(client)

    response = _upload(client, "RE: ../../etc\n")

    assert "Import abgebrochen" in response.get_data(as_text=True)
    assert [r.keyword for r in runtime.rule_store.load()] == ["ALT"]


def test_references_that_do_not_exist_here_are_reset_on_import(client, env):
    _, _, _, _, runtime = env
    _login(client)

    _upload(client, "version: 2\nrules:\n- keyword: RE\n  folder: r\n  account: '77'\n"
                    "  printer: '5'\n  print: true\n  archive: '9'\n")

    rule = runtime.rule_store.load()[0]
    assert (rule.account, rule.printer, rule.archive) == ("all", "", "")


def test_the_migration_note_is_shown_once_and_can_be_dismissed(client, env):
    from mail2nas.migrate import SETTING_RULES_NOTE

    _, _, settings, _, _ = env
    settings.set(SETTING_RULES_NOTE, "3 Zuordnung(en) aus mapping.yaml uebernommen.")
    _login(client)

    assert "uebernommen" in client.get("/mapping").get_data(as_text=True)
    client.post("/mapping/note/dismiss", data={"csrf_token": _csrf(client, "/mapping")})
    assert "uebernommen" not in client.get("/mapping").get_data(as_text=True)


# --- testing a mailbox ----------------------------------------------------------------


def test_a_mailbox_can_be_tested_from_the_ui(client, env, monkeypatch):
    from mail2nas import web as web_module

    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    monkeypatch.setattr(web_module, "test_imap", lambda account: 3)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}/test", data={
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "3 ungelesene" in response.get_data(as_text=True)


def test_a_failing_mailbox_test_says_why(client, env, monkeypatch):
    from mail2nas import web as web_module

    _, _, _, _, runtime = env
    account_id = _add_account(runtime)

    def refuse(account):
        raise OSError("AUTHENTICATIONFAILED")

    monkeypatch.setattr(web_module, "test_imap", refuse)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}/test", data={
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "AUTHENTICATIONFAILED" in response.get_data(as_text=True)
