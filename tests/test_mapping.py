from __future__ import annotations

import os
import textwrap

import pytest

from mail2nas.mapping import (
    Mapping,
    MappingError,
    Rule,
    load_rules,
    move_rule,
    save_rules,
    validate_keyword,
)
from mail2nas.storage import LocalStorage


def _write_rules(tmp_path, rules) -> None:
    """Write rules in the current format, as (keyword, folder[, account])."""
    save_rules(
        LocalStorage(str(tmp_path)),
        "mapping.yaml",
        [Rule.create(*rule) for rule in rules],
    )


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _mapping(tmp_path, fallback_folder="unsorted", relative="mapping.yaml") -> Mapping:
    return Mapping(LocalStorage(str(tmp_path)), relative, fallback_folder=fallback_folder)


def test_resolve_matches_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_resolve_prefers_longer_keyword_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_missing_mapping_file_falls_back_to_default(tmp_path):
    mapping = _mapping(tmp_path, relative="does-not-exist.yaml")

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    _write_mapping(mapping_path, "RE: invoices\n")
    # Nudge mtime forward in case the filesystem has coarse timestamp resolution.
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "invoices"


def test_broken_yaml_keeps_previous_rules_instead_of_raising(tmp_path):
    """A half-written mapping.yaml on the share must not take the service down."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()  # must not raise

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_non_mapping_yaml_keeps_previous_rules(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    mapping_path.write_text("- just\n- a\n- list\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_broken_yaml_is_not_re_reported_every_cycle(tmp_path, caplog):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    with caplog.at_level("ERROR"):
        mapping.reload()
        mapping.reload()
        mapping.reload()

    assert len([r for r in caplog.records if r.levelname == "ERROR"]) == 1


# --- priority: explicit order, first match wins --------------------------------


def test_first_matching_rule_wins_regardless_of_keyword_length(tmp_path):
    """Order is explicit now - a short keyword placed first beats a longer one."""
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


def test_moving_a_rule_up_changes_which_one_wins(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    rules = load_rules(LocalStorage(str(tmp_path)), "mapping.yaml")

    save_rules(LocalStorage(str(tmp_path)), "mapping.yaml", move_rule(rules, 1, -1))

    assert _mapping(tmp_path).resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


def test_moving_beyond_the_ends_is_a_no_op(tmp_path):
    rules = [Rule.create("A", "a"), Rule.create("B", "b")]

    assert [r.keyword for r in move_rule(rules, 0, -1)] == ["A", "B"]
    assert [r.keyword for r in move_rule(rules, 1, 1)] == ["A", "B"]


# --- legacy format --------------------------------------------------------------


def test_old_flat_file_is_read_with_its_original_priority(tmp_path):
    """The pre-2.0 format matched the longest keyword first; migration must not
    change which folder a mail lands in."""
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"
    assert mapping.resolve("RE-1")[0] == "rechnungen"


def test_saving_writes_the_versioned_format(tmp_path):
    storage = LocalStorage(str(tmp_path))
    save_rules(storage, "mapping.yaml", [Rule.create("RE", "rechnungen", "2")])

    text = storage.read_text("mapping.yaml")

    assert "version: 2" in text
    assert "keyword: RE" in text
    assert "account: '2'" in text


# --- wildcards --------------------------------------------------------------------


@pytest.mark.parametrize(
    "keyword,subject,expected",
    [
        ("RE*", "Ihre RE-4711", True),
        ("RE*2026", "RE-4711 vom 03.2026", True),
        ("RE*2026", "RE-4711 vom 03.2025", False),
        ("Rechn?ng", "Ihre Rechnung", True),
        ("Rechn?ng", "Ihre Rechnuung", False),
        ("*Rechnung*", "Ihre Rechnung 1", True),
        ("Rechnung", "Ihre RECHNUNG 1", True),
    ],
)
def test_wildcard_and_case_matching(tmp_path, keyword, subject, expected):
    _write_rules(tmp_path, [(keyword, "treffer")])

    folder, _ = _mapping(tmp_path).resolve(subject)

    assert (folder == "treffer") is expected


def test_wildcards_stay_within_substring_search(tmp_path):
    """A pattern is not anchored, so it may match in the middle of a subject."""
    _write_rules(tmp_path, [("RE*47", "treffer")])

    assert _mapping(tmp_path).resolve("Betreff: Ihre RE-4711 anbei")[0] == "treffer"


def test_a_regex_metacharacter_in_a_keyword_is_literal(tmp_path):
    """Only * and ? are wildcards - the rest must not be interpreted."""
    _write_rules(tmp_path, [("RE.*", "treffer")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("RE.4711")[0] == "treffer"
    assert mapping.resolve("REX4711")[0] == "unsorted"


def test_keyword_of_only_wildcards_is_rejected():
    with pytest.raises(MappingError):
        validate_keyword("***", [])


# --- per-account rules --------------------------------------------------------------


def test_a_rule_can_be_limited_to_one_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen", "2")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="2")[0] == "rechnungen"
    assert mapping.resolve("Rechnung 1", account_id="1")[0] == "unsorted"


def test_rules_for_all_accounts_match_every_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="7")[0] == "rechnungen"


def test_an_account_specific_rule_is_skipped_for_other_accounts(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "nur-konto-2", "2"), ("Rechnung", "alle")])

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung", account_id="2")[0] == "nur-konto-2"
    assert mapping.resolve("Rechnung", account_id="1")[0] == "alle"


def test_a_pattern_with_too_many_wildcards_is_rejected_in_the_ui():
    with pytest.raises(MappingError, match="Platzhalter"):
        validate_keyword("a*b*c*d*e*f*g", [])


def test_a_hand_written_pattern_with_too_many_wildcards_degrades_to_literal(tmp_path):
    """Loaded from the share it must not raise - and must not be run as a regex."""
    _write_mapping(tmp_path / "mapping.yaml", 'version: 2\nrules:\n- keyword: "a*b*c*d*e*f*g"\n  folder: t\n')

    mapping = _mapping(tmp_path)

    assert mapping.resolve("a" * 200 + "g")[0] == "unsorted"
    assert mapping.resolve("a*b*c*d*e*f*g")[0] == "t"


def test_matching_a_huge_body_stays_bounded(tmp_path):
    """A wildcard pattern must not be run against an unbounded amount of text."""
    import time

    _write_rules(tmp_path, [("Rechnung*Ende", "treffer")])
    mapping = _mapping(tmp_path)

    started = time.monotonic()
    folder, _ = mapping.resolve("Rechnung " + ("x" * 2_000_000))
    assert folder == "unsorted"
    assert time.monotonic() - started < 5
