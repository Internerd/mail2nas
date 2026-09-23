from __future__ import annotations

import textwrap

import pytest

from mail2nas.mapping import (
    Mapping,
    MappingError,
    Rule,
    RuleStore,
    dump_rules,
    move_rule,
    rules_from_yaml,
    set_printing,
    validate_keyword,
)


def _store(tmp_path) -> RuleStore:
    return RuleStore(str(tmp_path / "state.db"))


def _write_rules(tmp_path, rules) -> None:
    """Store rules as (keyword, folder[, account]) tuples."""
    _store(tmp_path).save([Rule.create(*rule) for rule in rules])


def _write_mapping(path, content: str) -> None:
    """Store the rules of a YAML snippet - as an import or the migration would."""
    _store(path.parent).save(rules_from_yaml(textwrap.dedent(content)))


def _mapping(tmp_path, fallback_folder="unsorted") -> Mapping:
    return Mapping(_store(tmp_path), fallback_folder)


def load_rules(tmp_path) -> list[Rule]:
    return _store(tmp_path).load()


def save_rules(tmp_path, rules) -> None:
    _store(tmp_path).save(rules)


def test_resolve_matches_case_insensitive(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_the_fallback_follows_the_settings_page(tmp_path):
    current = {"folder": "unsorted"}
    mapping = Mapping(_store(tmp_path), lambda: current["folder"])

    current["folder"] = "sonstiges"

    assert mapping.resolve("Newsletter")[0] == "sonstiges"


def test_an_old_flat_file_keeps_its_longest_keyword_first_priority(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_no_rules_means_everything_goes_to_the_fallback(tmp_path):
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes_made_in_the_ui(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    _write_rules(tmp_path, [("RE", "invoices")])
    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "invoices"


def test_saving_through_the_mapping_takes_effect_at_once(tmp_path):
    mapping = _mapping(tmp_path)

    mapping.save([Rule.create("LS", "lieferscheine")])

    assert mapping.resolve("LS 7")[0] == "lieferscheine"
    assert [r.keyword for r in load_rules(tmp_path)] == ["LS"]


def test_the_order_survives_the_database(tmp_path):
    rules = [Rule.create(k, "x") for k in ("Zeta", "Alpha", "Mitte")]
    save_rules(tmp_path, rules)

    assert [r.keyword for r in load_rules(tmp_path)] == ["Zeta", "Alpha", "Mitte"]


@pytest.mark.parametrize("text", ["RE: [unclosed\n", "- just\n- a\n- list\n"])
def test_an_unreadable_import_is_refused_with_a_reason(text):
    with pytest.raises(MappingError):
        rules_from_yaml(text)


def test_export_and_import_round_trip(tmp_path):
    rules = [
        Rule.create("Rechnungskorrektur", "korrekturen"),
        Rule.create("RE*", "rechnungen", "2", True, "1", "3"),
    ]

    assert rules_from_yaml(dump_rules(rules)) == rules


# --- priority: explicit order, first match wins --------------------------------


def test_first_matching_rule_wins_regardless_of_keyword_length(tmp_path):
    """Order is explicit now - a short keyword placed first beats a longer one."""
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


def test_moving_a_rule_up_changes_which_one_wins(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    rules = load_rules(tmp_path)

    save_rules(tmp_path, move_rule(rules, 1, -1))

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


def test_the_export_uses_the_versioned_format(tmp_path):
    text = dump_rules([Rule.create("RE", "rechnungen", "2")])

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


# --- printing per rule ------------------------------------------------------------


def test_a_rule_carries_its_print_settings(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: Rechnung
            folder: rechnungen
            print: true
            printer: "3"
    """)

    rule = _mapping(tmp_path).match("Rechnung 4711")

    assert (rule.folder, rule.print_attachments, rule.printer) == ("rechnungen", True, "3")


def test_a_rule_without_print_settings_prints_nothing(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    rule = _mapping(tmp_path).match("RE-1")

    assert rule.print_attachments is False
    assert rule.printer == ""


def test_print_settings_survive_a_save_and_reload(tmp_path):
    save_rules(tmp_path, [Rule.create("RE", "rechnungen", "all", True, "2")])

    reloaded = load_rules(tmp_path)[0]

    assert (reloaded.print_attachments, reloaded.printer) == (True, "2")


def test_an_export_without_printing_stays_short(tmp_path):
    text = dump_rules([Rule.create("RE", "rechnungen")])

    assert "print" not in text
    assert "printer" not in text


def test_a_hand_written_yes_is_read_as_printing(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: RE
            folder: rechnungen
            print: "ja"
    """)

    assert _mapping(tmp_path).match("RE-1").print_attachments is True


def test_switching_printing_off_drops_the_printer(tmp_path):
    rule = Rule.create("RE", "rechnungen", "all", True, "2")

    assert set_printing(rule, False, "2").printer == ""
    assert set_printing(rule, True, "5").printer == "5"


def test_match_returns_nothing_when_no_rule_applies(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    assert _mapping(tmp_path).match("Newsletter") is None
