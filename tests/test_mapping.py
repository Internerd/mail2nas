from __future__ import annotations

import os
import textwrap

import pytest

from mail2nas.mapping import Mapping


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def test_resolve_matches_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_resolve_prefers_longer_keyword_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_missing_mapping_file_falls_back_to_default(tmp_path):
    mapping = Mapping(str(tmp_path / "does-not-exist.yaml"), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
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
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()  # must not raise

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_non_mapping_yaml_keeps_previous_rules(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("- just\n- a\n- list\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_broken_yaml_is_not_re_reported_every_cycle(tmp_path, caplog):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    with caplog.at_level("ERROR"):
        mapping.reload()
        mapping.reload()
        mapping.reload()

    assert len([r for r in caplog.records if r.levelname == "ERROR"]) == 1


# --- v2 format: explicit order, wildcards, per-account rules -----------------

from mail2nas.mapping import ALL_ACCOUNTS, Rule, dump_rules  # noqa: E402


def test_v2_order_defines_priority_not_keyword_length(tmp_path):
    """The first matching rule wins, even if a longer keyword matches later."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: RE
            folder: rechnungen
          - match: Rechnungskorrektur
            folder: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


def test_v2_reordering_changes_the_winner(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnungskorrektur
            folder: korrekturen
          - match: RE
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


def test_v1_dict_format_still_works_with_length_priority(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


@pytest.mark.parametrize(
    "pattern,text,expected",
    [
        ("Rechnung*", "rechnung_4711.pdf", True),
        ("Rechnung*", "meine rechnung", False),   # anchored at the start
        ("*Rechnung*", "meine rechnung 1", True),
        ("RE-????", "re-2024", True),
        ("RE-????", "re-24", False),
        ("*.pdf", "beleg.pdf", True),
        ("*.pdf", "beleg.exe", False),
    ],
)
def test_wildcards(tmp_path, pattern, text, expected):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, f"""
        version: 2
        rules:
          - match: "{pattern}"
            folder: treffer
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert (mapping.resolve(text)[0] == "treffer") is expected


def test_plain_keyword_stays_a_substring_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnung
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Ihre Rechnung 4711")[0] == "rechnungen"


def test_wildcards_are_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: "RECHNUNG*"
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("rechnung_1.pdf")[0] == "rechnungen"


def test_rule_limited_to_one_account_is_skipped_for_others(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnung
            folder: privat
            account: privatkonto
          - match: Rechnung
            folder: firma
            account: all
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnung 1", account="privatkonto")[0] == "privat"
    assert mapping.resolve("Rechnung 1", account="firmenkonto")[0] == "firma"


def test_dump_rules_roundtrips_through_the_loader(tmp_path):
    rules = [
        Rule(match="Rechnung*", folder="rechnungen", account=ALL_ACCOUNTS),
        Rule(match="LS", folder="lieferscheine", account="konto2"),
    ]
    mapping_path = tmp_path / "mapping.yaml"
    mapping_path.write_text(dump_rules(rules), encoding="utf-8")

    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.rules == rules


def test_save_persists_order_and_is_reloaded(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "version: 2\nrules: []\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping.save([Rule(match="LS", folder="lieferscheine"), Rule(match="RE", folder="rechnungen")])

    assert Mapping(str(mapping_path), "unsorted").rules == mapping.rules
    assert mapping.resolve("RE und LS")[0] == "lieferscheine"


def test_rule_missing_folder_is_rejected_and_previous_rules_kept(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("version: 2\nrules:\n  - match: RE\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))
    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"
