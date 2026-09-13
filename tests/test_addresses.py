from __future__ import annotations

import pytest

from mail2nas.addresses import AddressError, AddressRule, AddressStore, matches_address


def _store(tmp_path) -> AddressStore:
    return AddressStore(str(tmp_path / "state.db"))


def _rule(**overrides) -> AddressRule:
    values = dict(
        id=1,
        name="Drucker Buero",
        recipient="drucker@firma.de",
        sender="",
        print_attachments=True,
        printer="",
        archive_attachments=True,
        folder="",
        enabled=True,
    )
    values.update(overrides)
    return AddressRule(**values)


# --- address patterns --------------------------------------------------------


@pytest.mark.parametrize(
    "pattern,address,expected",
    [
        ("drucker@firma.de", "drucker@firma.de", True),
        ("drucker@firma.de", "DRUCKER@Firma.DE", True),
        ("drucker@firma.de", "chef@firma.de", False),
        ("@firma.de", "irgendwer@firma.de", True),
        ("@firma.de", "jemand@fremd.de", False),
        ("@firma.de", "jemand@subfirma.de", False),
        ("drucker-*@firma.de", "drucker-eg@firma.de", True),
        ("drucker-*@firma.de", "buchhaltung@firma.de", False),
        ("drucker-??@firma.de", "drucker-eg@firma.de", True),
        ("drucker-??@firma.de", "drucker-erdgeschoss@firma.de", False),
        ("", "drucker@firma.de", False),
        ("drucker@firma.de", "", False),
    ],
)
def test_matches_address(pattern, address, expected):
    assert matches_address(pattern, address) is expected


def test_a_pattern_with_absurdly_many_wildcards_is_ignored():
    """Matching cost is bounded: the text comes from outside."""
    assert matches_address("a*a*a*a*a*a*a*@firma.de", "aaaaaaaa@firma.de") is False


# --- rule matching -----------------------------------------------------------


def test_recipient_only_rule_ignores_the_sender():
    rule = _rule(recipient="drucker@firma.de")

    assert rule.matches(["drucker@firma.de"], "fremder@example.com") is True


def test_any_of_the_recipients_may_match():
    """A mail to several people still counts as addressed to the printer."""
    rule = _rule(recipient="drucker@firma.de")

    assert rule.matches(["chef@firma.de", "drucker@firma.de"], "a@b.c") is True


def test_sender_only_rule_matches_by_sender():
    rule = _rule(recipient="", sender="scanner@firma.de")

    assert rule.matches(["archiv@firma.de"], "scanner@firma.de") is True


def test_both_patterns_have_to_match():
    """The sender restricts who may print, it is not a second trigger."""
    rule = _rule(recipient="drucker@firma.de", sender="@firma.de")

    assert rule.matches(["drucker@firma.de"], "kollege@firma.de") is True
    assert rule.matches(["drucker@firma.de"], "fremder@example.com") is False
    assert rule.matches(["anderes@firma.de"], "kollege@firma.de") is False


def test_a_rule_without_any_pattern_never_matches():
    """Belt and braces for a hand-edited database: never print everything."""
    rule = _rule(recipient="", sender="")

    assert rule.matches(["drucker@firma.de"], "chef@firma.de") is False


# --- store -------------------------------------------------------------------


def test_add_and_read_back(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(
        name="Buero", recipient="drucker@firma.de", print_attachments=True, printer="3"
    )

    stored = store.get(rule_id)
    assert (stored.recipient, stored.printer, stored.print_attachments) == (
        "drucker@firma.de",
        "3",
        True,
    )


def test_update_keeps_the_fields_not_sent(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(name="Buero", recipient="drucker@firma.de", folder="ausdrucke")

    store.update(rule_id, name="Buero EG")

    stored = store.get(rule_id)
    assert (stored.name, stored.folder) == ("Buero EG", "ausdrucke")


def test_delete(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(recipient="drucker@firma.de")

    store.delete(rule_id)

    assert store.get(rule_id) is None


def test_first_matching_rule_wins(tmp_path):
    """Two aliases covering one mail must not print it twice."""
    store = _store(tmp_path)
    store.add(name="Speziell", recipient="drucker-eg@firma.de")
    store.add(name="Allgemein", recipient="@firma.de")

    assert store.match(["drucker-eg@firma.de"], "chef@firma.de").name == "Speziell"


def test_disabled_rules_are_skipped(tmp_path):
    store = _store(tmp_path)
    store.add(name="Aus", recipient="drucker@firma.de", enabled=False)

    assert store.match(["drucker@firma.de"], "chef@firma.de") is None


def test_no_match_returns_none(tmp_path):
    store = _store(tmp_path)
    store.add(recipient="drucker@firma.de")

    assert store.match(["archiv@firma.de"], "chef@firma.de") is None


def test_deleting_a_printer_unpins_the_rules_using_it(tmp_path):
    store = _store(tmp_path)
    rule_id = store.add(recipient="drucker@firma.de", print_attachments=True, printer="7")
    store.add(recipient="anderes@firma.de", print_attachments=True, printer="8")

    assert store.clear_printer("7") == 1

    assert store.get(rule_id).printer == ""


def test_the_table_survives_a_second_open(tmp_path):
    store = _store(tmp_path)
    store.add(recipient="drucker@firma.de")

    assert len(AddressStore(str(tmp_path / "state.db")).all()) == 1


# --- validation --------------------------------------------------------------


def test_an_entry_without_any_address_is_rejected(tmp_path):
    with pytest.raises(AddressError, match="Empfaengeradresse"):
        _store(tmp_path).add(name="Leer")


@pytest.mark.parametrize(
    "pattern", ["kein-at-zeichen", "zwei@adressen.de, noch@eine.de", "mit leerzeichen@firma.de"]
)
def test_unusable_recipient_patterns_are_rejected(tmp_path, pattern):
    with pytest.raises(AddressError):
        _store(tmp_path).add(recipient=pattern)


def test_neither_printing_nor_filing_is_rejected(tmp_path):
    """That combination would silently throw the attachment away."""
    with pytest.raises(AddressError, match="verworfen"):
        _store(tmp_path).add(
            recipient="drucker@firma.de", print_attachments=False, archive_attachments=False
        )


def test_a_folder_that_escapes_the_archive_is_rejected(tmp_path):
    with pytest.raises(AddressError, match="Zielordner"):
        _store(tmp_path).add(recipient="drucker@firma.de", folder="../woanders")


def test_the_address_is_normalised(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(recipient="  Drucker@Firma.DE  ", folder="ausdrucke/2026/")

    stored = store.get(rule_id)
    assert stored.recipient == "drucker@firma.de"
    assert stored.folder == "ausdrucke/2026"


def test_the_name_defaults_to_the_address(tmp_path):
    store = _store(tmp_path)

    rule_id = store.add(recipient="drucker@firma.de")

    assert store.get(rule_id).name == "drucker@firma.de"
