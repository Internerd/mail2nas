from __future__ import annotations

import dataclasses

import pytest

from mail2nas.mapping import ALL_ACCOUNTS, Mapping, Rule
from mail2nas.settings import Account, Printer, Settings, Share
from mail2nas.web import create_app
from tests.test_archiver import _make_config

PASSWORD = "s3cret"


@pytest.fixture
def env(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
    nas2 = tmp_path / "nas2"
    nas2.mkdir()
    data = tmp_path / "data"
    data.mkdir()

    config = dataclasses.replace(
        _make_config(share, storage_root=str(share), state_db_path=str(data / "state.db")),
        web_enabled=True,
        web_user="admin",
        web_password=PASSWORD,
    )
    settings = Settings(
        accounts=[
            Account(id="haupt", label="Hauptpostfach", host="imap.x", user="a@x", password="pw"),
            Account(id="zweit", label="Zweitkonto", host="imap.y", user="b@y", password="pw"),
        ],
        shares=[
            Share(id="default", label="NAS", path=str(share)),
            Share(id="nas2", label="NAS 2", path=str(nas2)),
        ],
        printers=[
            Printer(id="kopierer", label="Kopierer Flur", sender="scan@example.com",
                    source_folder="scans", target_folder="eingang")
        ],
        blocked_extensions=["exe", "bat"],
    )
    settings.save(config)
    mapping = Mapping(str(share / "mapping.yaml"), "unsorted")
    mapping.save([Rule("RE", "rechnungen"), Rule("LS", "lieferscheine")])

    app = create_app(config, settings, mapping)
    app.config.update(TESTING=True)
    return {
        "app": app,
        "config": config,
        "settings": settings,
        "mapping": mapping,
        "share": share,
        "nas2": nas2,
    }


@pytest.fixture
def client(env):
    return env["app"].test_client()


def login(client):
    client.post("/login", data={"user": "admin", "password": PASSWORD})
    with client.session_transaction() as sess:
        sess["csrf"] = "test-token"
    return "test-token"


# --- authentication ----------------------------------------------------------


@pytest.mark.parametrize("path", ["/", "/accounts", "/settings", "/shares", "/printers"])
def test_pages_require_login(client, path):
    response = client.get(path)

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_login_rejects_wrong_password(client):
    client.post("/login", data={"user": "admin", "password": "wrong"})

    assert client.get("/").status_code == 302


def test_login_accepts_correct_password(client):
    login(client)

    assert client.get("/").status_code == 200


def test_logout_ends_the_session(client):
    token = login(client)
    client.post("/logout", data={"csrf_token": token})

    assert client.get("/").status_code == 302


# --- CSRF --------------------------------------------------------------------


def test_post_without_csrf_token_is_rejected(client):
    login(client)

    response = client.post("/rules/add", data={"match": "AB", "folder": "ab"})

    assert response.status_code == 400


def test_post_with_wrong_csrf_token_is_rejected(client):
    login(client)

    response = client.post("/rules/add", data={"csrf_token": "nope", "match": "AB", "folder": "ab"})

    assert response.status_code == 400


# --- rule ordering (the arrows) ---------------------------------------------


def test_move_rule_down_changes_priority(client, env):
    token = login(client)

    client.post("/rules/0/move/down", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS", "RE"]


def test_move_rule_up_changes_priority(client, env):
    token = login(client)

    client.post("/rules/1/move/up", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS", "RE"]


def test_move_beyond_the_ends_is_a_no_op(client, env):
    token = login(client)

    client.post("/rules/0/move/up", data={"csrf_token": token})
    client.post("/rules/1/move/down", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["RE", "LS"]


def test_reordering_survives_a_reload_from_disk(client, env):
    token = login(client)
    client.post("/rules/0/move/down", data={"csrf_token": token})

    reloaded = Mapping(str(env["mapping"].path), "unsorted")

    assert [r.match for r in reloaded.rules] == ["LS", "RE"]


# --- rule CRUD ---------------------------------------------------------------


def test_add_rule_with_wildcard_and_account(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Mahnung*", "folder": "mahnungen", "account": "zweit"},
    )

    added = env["mapping"].rules[-1]
    assert (added.match, added.folder, added.account) == ("Mahnung*", "mahnungen", "zweit")


def test_add_rule_rejects_folder_escaping_the_share(client, env):
    token = login(client)

    client.post(
        "/rules/add", data={"csrf_token": token, "match": "X", "folder": "../../etc"}
    )

    assert all(r.folder != "../../etc" for r in env["mapping"].rules)


def test_update_rule_changes_pattern_and_account(client, env):
    token = login(client)

    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE-*", "folder": "rechnungen", "account": "haupt"},
    )

    assert env["mapping"].rules[0] == Rule("RE-*", "rechnungen", "haupt")


def test_delete_rule(client, env):
    token = login(client)

    client.post("/rules/0/delete", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS"]


# --- accounts ----------------------------------------------------------------


def test_add_account(client, env):
    token = login(client)

    client.post(
        "/accounts/save",
        data={
            "csrf_token": token, "id": "", "label": "Drittkonto", "host": "imap.z",
            "user": "c@z", "password": "geheim", "port": "993", "ssl": "on",
            "folder": "INBOX", "mode": "poll", "enabled": "on",
        },
    )

    saved = Settings.load(env["config"])
    assert any(a.label == "Drittkonto" and a.password == "geheim" for a in saved.accounts)


def test_editing_an_account_with_empty_password_keeps_the_old_one(client, env):
    token = login(client)

    client.post(
        "/accounts/save",
        data={
            "csrf_token": token, "id": "haupt", "label": "Umbenannt", "host": "imap.x",
            "user": "a@x", "password": "", "port": "993", "folder": "INBOX",
            "mode": "poll", "enabled": "on",
        },
    )

    saved = Settings.load(env["config"])
    account = saved.account("haupt")
    assert account.label == "Umbenannt"
    assert account.password == "pw"


def test_deleting_an_account_unpins_its_rules(client, env):
    token = login(client)
    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE", "folder": "rechnungen", "account": "zweit"},
    )

    client.post("/accounts/zweit/delete", data={"csrf_token": token})

    saved = Settings.load(env["config"])
    assert saved.account("zweit") is None
    # the rule must not silently stop matching for ever
    assert all(r.account == ALL_ACCOUNTS for r in env["mapping"].rules)


# --- settings, including moving the mapping file -----------------------------


def test_moving_the_mapping_file_carries_the_rules_along(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "config/mapping.yaml",
            "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
            "blocked_extensions": "exe, bat",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    new_path = env["share"] / "config" / "mapping.yaml"
    assert new_path.exists()
    assert not (env["share"] / "mapping.yaml").exists()
    assert [r.match for r in Mapping(str(new_path), "unsorted").rules] == ["RE", "LS"]


@pytest.mark.parametrize("hostile", ["../../etc/passwd", "/etc/passwd"])
def test_mapping_path_cannot_escape_the_share(client, env, hostile):
    token = login(client)
    before = str(env["mapping"].path)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": hostile,
            "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20",
        },
    )

    assert str(env["mapping"].path) == before
    assert Settings.load(env["config"]).mapping_path == "mapping.yaml"


def test_settings_are_persisted(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml",
            "fallback_folder": "sonstiges", "quarantine_folder": "quarantaene",
            "match_body": "on", "filename_prefix": "date", "poll_interval": "60",
            "max_attachment_size_mb": "10", "max_message_size_mb": "20",
            "max_attachments_per_message": "5",
        },
    )

    saved = Settings.load(env["config"])
    assert saved.fallback_folder == "sonstiges"
    assert saved.match_body is True
    assert saved.filename_prefix == "date"
    assert saved.max_attachment_size_mb == 10


def test_config_file_is_written_with_restrictive_permissions(env):
    path = Settings.path_for(env["config"])

    assert oct(path.stat().st_mode & 0o777) == "0o600"


# --- shares (several NAS) ----------------------------------------------------


def test_add_share(client, env, tmp_path):
    token = login(client)
    nas3 = tmp_path / "nas3"
    nas3.mkdir()

    client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "", "label": "NAS 3", "path": str(nas3), "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert any(s.label == "NAS 3" and s.path == str(nas3) for s in saved.shares)


def test_edit_share_keeps_its_id(client, env, tmp_path):
    token = login(client)
    moved = tmp_path / "verschoben"
    moved.mkdir()

    client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "nas2", "label": "NAS 2", "path": str(moved),
              "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert saved.share("nas2").path == str(moved)


@pytest.mark.parametrize("path", ["relativ/pfad", "/", "/etc", ""])
def test_share_path_must_be_an_absolute_non_system_mount_point(client, env, path):
    token = login(client)

    client.post(
        "/shares/save", data={"csrf_token": token, "id": "", "label": "Boese", "path": path}
    )

    saved = Settings.load(env["config"])
    assert all(s.label != "Boese" for s in saved.shares)


def test_share_that_is_not_mounted_yet_is_saved_with_a_warning(client, env, tmp_path):
    token = login(client)

    response = client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "", "label": "Spaeter", "path": str(tmp_path / "kommt-noch"),
              "enabled": "on"},
        follow_redirects=True,
    )

    assert "Achtung" in response.get_data(as_text=True)
    assert any(s.label == "Spaeter" for s in Settings.load(env["config"]).shares)


def test_deleting_a_share_moves_its_rules_to_the_default_one(client, env):
    token = login(client)
    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE", "folder": "rechnungen", "share": "nas2",
              "account": ALL_ACCOUNTS},
    )
    assert env["mapping"].rules[0].share == "nas2"

    client.post("/shares/nas2/delete", data={"csrf_token": token})

    assert Settings.load(env["config"]).share("nas2") is None
    assert all(r.share == "" for r in env["mapping"].rules)


def test_deleting_a_share_unpins_the_printers_using_it(client, env):
    token = login(client)
    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "kopierer", "label": "Kopierer Flur",
              "sender": "scan@example.com", "source_share": "nas2", "source_folder": "scans",
              "target_share": "nas2", "target_folder": "eingang", "enabled": "on"},
    )

    client.post("/shares/nas2/delete", data={"csrf_token": token})

    printer = Settings.load(env["config"]).printer("kopierer")
    assert (printer.source_share, printer.target_share) == ("", "")


def test_the_last_share_cannot_be_deleted(client, env):
    token = login(client)
    client.post("/shares/nas2/delete", data={"csrf_token": token})

    client.post("/shares/default/delete", data={"csrf_token": token})

    assert len(Settings.load(env["config"]).shares) == 1


# --- rules on a share --------------------------------------------------------


def test_add_rule_for_a_specific_share(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Angebot", "folder": "angebote", "share": "nas2"},
    )

    assert env["mapping"].rules[-1].share == "nas2"


def test_rule_for_an_unknown_share_is_rejected(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Angebot", "folder": "angebote", "share": "gibtsnicht"},
    )

    assert all(r.match != "Angebot" for r in env["mapping"].rules)


def test_rule_folder_is_checked_against_the_share_it_names(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "X", "folder": "../raus", "share": "nas2"},
    )

    assert all(r.folder != "../raus" for r in env["mapping"].rules)


# --- printers ----------------------------------------------------------------


def test_add_printer(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Scanner Lager",
              "sender": "lager@scanner.lan", "source_share": "", "source_folder": "scans/lager",
              "target_share": "nas2", "target_folder": "lager", "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    printer = next(p for p in saved.printers if p.label == "Scanner Lager")
    assert printer.sender == "lager@scanner.lan"
    assert printer.source_folder == "scans/lager"
    assert printer.target_share == "nas2"


def test_printer_needs_a_mail_address_or_a_pickup_folder(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Leer", "sender": "",
              "source_folder": "", "target_folder": "irgendwo", "enabled": "on"},
    )

    assert all(p.label != "Leer" for p in Settings.load(env["config"]).printers)


def test_printer_needs_a_label(client, env):
    token = login(client)

    before = len(Settings.load(env["config"]).printers)
    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "", "sender": "x@y.z", "enabled": "on"},
    )

    assert len(Settings.load(env["config"]).printers) == before


def test_printer_target_inside_its_pickup_folder_is_rejected(client, env):
    """That would re-import the same document on every single cycle."""
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Schleife", "sender": "",
              "source_share": "", "source_folder": "scans",
              "target_share": "", "target_folder": "scans/fertig", "enabled": "on"},
    )

    assert all(p.label != "Schleife" for p in Settings.load(env["config"]).printers)


def test_printer_folder_cannot_escape_the_share(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Boese", "sender": "",
              "source_folder": "../../etc", "target_folder": "eingang", "enabled": "on"},
    )

    assert all(p.label != "Boese" for p in Settings.load(env["config"]).printers)


def test_edit_printer_keeps_its_id(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "kopierer", "label": "Kopierer Flur (neu)",
              "sender": "scan@example.com", "source_folder": "scans",
              "target_folder": "eingang", "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert saved.printer("kopierer").label == "Kopierer Flur (neu)"
    assert len(saved.printers) == 1


def test_delete_printer(client, env):
    token = login(client)

    client.post("/printers/kopierer/delete", data={"csrf_token": token})

    assert Settings.load(env["config"]).printers == []


# --- quarantine extensions ---------------------------------------------------


def test_blocked_extensions_are_editable(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
            "quarantine_folder": "quarantaene", "blocked_extensions": ".EXE, com; bat\nps1",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert Settings.load(env["config"]).blocked_extensions == ["exe", "com", "bat", "ps1"]


def test_blocked_extensions_can_be_emptied(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
            "quarantine_folder": "quarantaene", "blocked_extensions": "",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert Settings.load(env["config"]).blocked_extensions == []


def test_changed_fallback_folder_takes_effect_without_a_restart(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "sonstiges",
            "quarantine_folder": "quarantaene", "blocked_extensions": "exe",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert env["mapping"].resolve("xyz").folder == "sonstiges"


@pytest.mark.parametrize("field", ["fallback_folder", "quarantine_folder"])
def test_settings_reject_a_folder_that_leaves_the_share(client, env, field):
    token = login(client)
    data = {
        "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
        "quarantine_folder": "quarantaene", "blocked_extensions": "exe",
        "filename_prefix": "date_sender", "poll_interval": "300",
        "max_attachment_size_mb": "25", "max_message_size_mb": "50",
        "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
    }
    data[field] = "../raus"

    client.post("/settings", data=data)

    saved = Settings.load(env["config"])
    assert getattr(saved, field) != "../raus"
