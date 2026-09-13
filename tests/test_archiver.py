from __future__ import annotations

import textwrap
from email.message import EmailMessage

from mail2nas.archiver import Archiver
from mail2nas.config import DEFAULT_BLOCKED_EXTENSIONS, Config
from mail2nas.mapping import Mapping, Target
from mail2nas.settings import Printer, Share
from mail2nas.shares import ShareSet
from mail2nas.state import ProcessedStore


def _make_config(tmp_path, **overrides) -> Config:
    defaults = dict(
        imap_host="imap.example.com",
        imap_port=993,
        imap_user="u",
        imap_password="p",
        imap_ssl=True,
        imap_folder="INBOX",
        imap_processed_folder=None,
        imap_oversized_folder=None,
        imap_mode="poll",
        poll_interval=60,
        storage_root=str(tmp_path),
        mapping_path="mapping.yaml",
        fallback_folder="unsorted",
        match_body=False,
        filename_prefix="date_sender",
        max_attachment_size_mb=25,
        max_message_size_mb=50,
        max_attachments_per_message=20,
        blocked_extensions=frozenset(
            e.strip() for e in DEFAULT_BLOCKED_EXTENSIONS.split(",")
        ),
        quarantine_folder="quarantaene",
        state_db_path=str(tmp_path / "state.db"),
        dry_run=False,
    )
    defaults.update(overrides)
    return Config(**defaults)


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    shares=None,
    printers=None,
    **config_overrides,
) -> Archiver:
    config = _make_config(tmp_path, **config_overrides)
    mapping_path = tmp_path / "mapping.yaml"
    if mapping_content is not None:
        _write_mapping(mapping_path, mapping_content)
    mapping = Mapping(str(mapping_path), config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    return Archiver(config, mapping, store, shares=shares, printers=printers)


class FakeIMAPClient:
    """Minimal stand-in for imapclient.IMAPClient, just enough for _process_message."""

    def __init__(self, uid: int, raw: bytes):
        self._uid = uid
        self._raw = raw
        self.flags_added: list[tuple[list[int], list[bytes]]] = []
        self.moved_to: list[tuple[list[int], str]] = []

    def fetch(self, uids, parts):
        assert uids == [self._uid]
        result: dict = {}
        for uid in uids:
            entry = {}
            if "RFC822.SIZE" in parts:
                entry[b"RFC822.SIZE"] = len(self._raw)
            if "RFC822" in parts:
                entry[b"RFC822"] = self._raw
            result[uid] = entry
        return result

    def add_flags(self, uids, flags):
        self.flags_added.append((list(uids), list(flags)))

    def move(self, uids, folder):
        self.moved_to.append((list(uids), folder))


def _build_message(subject: str, attachments: list[tuple[str, bytes]]) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    for filename, payload in attachments:
        msg.add_attachment(payload, maintype="application", subtype="octet-stream", filename=filename)
    return bytes(msg)


# --- attachment discovery / filename building -------------------------------


def test_iter_attachments_finds_named_parts(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Rechnung 123"
    msg.set_content("Hallo")
    msg.add_attachment(b"%PDF-1.4 fake", maintype="application", subtype="pdf", filename="rechnung.pdf")

    archiver = _make_archiver(tmp_path)
    attachments = list(archiver._iter_attachments(msg))

    assert len(attachments) == 1
    filename, payload = attachments[0]
    assert filename == "rechnung.pdf"
    assert payload.startswith(b"%PDF")


def test_iter_attachments_ignores_plain_body(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Newsletter"
    msg.set_content("Nur Text, kein Anhang")

    archiver = _make_archiver(tmp_path)

    assert list(archiver._iter_attachments(msg)) == []


def test_build_filename_date_sender_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date_sender")

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_lieferant_example.com_rechnung.pdf"


def test_build_filename_none_prefix_keeps_original_name(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="none")

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "rechnung.pdf"


def test_build_filename_date_only_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date")

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_rechnung.pdf"


# --- per-attachment folder resolution ----------------------------------------


def test_resolve_attachment_folder_prefers_attachment_filename_over_mail_subject(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            RE: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    # Mail-level match would be "rechnungen" (subject contains RE), but this
    # specific attachment's own filename literally says "Lieferschein".
    mail_target = archiver.mapping.resolve("RE-2024-001 mit Lieferschein")

    target, quarantined = archiver.filer.classify("Lieferschein_4711.pdf", mail_target)

    assert target.folder == "lieferscheine"
    assert target.keyword == "Lieferschein"
    assert quarantined is False


def test_resolve_attachment_folder_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_target = archiver.mapping.resolve("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    target, quarantined = archiver.filer.classify("anhang1.pdf", mail_target)

    assert target.folder == "rechnungen"
    assert target.keyword == "RE"
    assert quarantined is False


def test_resolve_attachment_folder_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    target, quarantined = archiver.filer.classify("Rechnung.exe", Target(folder="unsorted"))

    assert target.folder == "quarantaene"
    assert quarantined is True


# --- full message processing (size/count limits, quarantine, mail-level) ----


def test_process_message_splits_multiple_attachments_by_filename(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            Rechnung: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice-bytes"), ("Lieferschein_42.pdf", b"delivery-bytes")],
    )
    client = FakeIMAPClient(uid=1, raw=raw)

    archiver._process_message(client, 1)

    assert any(p.name.endswith("Rechnung_42.pdf") for p in (tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("Lieferschein_42.pdf") for p in (tmp_path / "lieferscheine").glob("*"))


def test_process_message_skips_oversized_message_without_reading_body(tmp_path):
    archiver = _make_archiver(tmp_path, max_message_size_mb=1)
    huge_raw = _build_message("Rechnung riesig", [("rechnung.pdf", b"x" * (2 * 1024 * 1024))])
    client = FakeIMAPClient(uid=7, raw=huge_raw)

    result = archiver._process_message(client, 7)

    assert result is True
    assert client.flags_added == [([7], [b"\\Seen"])]
    assert not (tmp_path / "rechnungen").exists()


def test_process_message_skips_only_oversized_attachment(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachment_size_mb=1, max_message_size_mb=50
    )
    raw = _build_message(
        "RE-1",
        [("gross.pdf", b"x" * (2 * 1024 * 1024)), ("klein.pdf", b"klein")],
    )
    client = FakeIMAPClient(uid=3, raw=raw)

    archiver._process_message(client, 3)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("klein.pdf") for p in saved)
    assert not any(p.name.endswith("gross.pdf") for p in saved)


def test_process_message_caps_attachment_count(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachments_per_message=2
    )
    raw = _build_message(
        "RE-1",
        [(f"a{i}.pdf", b"data") for i in range(5)],
    )
    client = FakeIMAPClient(uid=4, raw=raw)

    archiver._process_message(client, 4)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert len(saved) == 2


def test_process_message_quarantines_blocked_attachment(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ...")])
    client = FakeIMAPClient(uid=5, raw=raw)

    archiver._process_message(client, 5)

    assert not (tmp_path / "rechnungen").exists() or not any((tmp_path / "rechnungen").glob("*"))
    quarantined = list((tmp_path / "quarantaene").glob("*"))
    assert len(quarantined) == 1


def test_process_message_is_idempotent_for_already_processed_message_id(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("rechnung.pdf", b"data")])
    client = FakeIMAPClient(uid=6, raw=raw)

    archiver._process_message(client, 6)
    first_run_files = list((tmp_path / "rechnungen").glob("*"))
    archiver._process_message(client, 6)
    second_run_files = list((tmp_path / "rechnungen").glob("*"))

    assert len(first_run_files) == 1
    assert len(second_run_files) == 1


# --- untrusted mapping targets must not escape the storage root -------------


def test_process_message_confines_relative_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside-escape\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path.parent / "outside-escape").exists()
    # rejected target falls back rather than being written outside
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_process_message_confines_absolute_traversal_target(tmp_path):
    escape = tmp_path.parent / "absolute-escape"
    archiver = _make_archiver(tmp_path, mapping_content=f"RE: {escape}\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert not escape.exists()
    # rejected as a misconfiguration, so it lands in the fallback folder
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_target_dir_rejects_escape_and_uses_fallback(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver.filer.directory_for(Target(folder="../evil")) == tmp_path / "unsorted"
    assert archiver.filer.directory_for(Target(folder="rechnungen")) == tmp_path / "rechnungen"


def test_nested_mapping_target_is_supported(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen/2026\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert any((tmp_path / "rechnungen" / "2026").glob("*"))


def test_quarantine_still_wins_over_a_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert not (tmp_path.parent / "outside").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_attachments_are_written_atomically_without_temp_leftovers(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    names = [p.name for p in (tmp_path / "rechnungen").iterdir()]
    assert len(names) == 1
    assert not any(n.startswith(".mail2nas-tmp-") for n in names)


# --- several shares / several NAS -------------------------------------------


def _two_share_set(tmp_path):
    """<tmp_path> is the default share, <tmp_path>/nas2-share the second one."""
    second = tmp_path / "nas2-share"
    second.mkdir(exist_ok=True)
    return (
        ShareSet(
            [Share(id="nas1", path=str(tmp_path)), Share(id="nas2", path=str(second))],
            fallback_root=str(tmp_path),
        ),
        second,
    )


def test_rule_files_onto_the_share_it_names(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: nas2
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "rechnungen").exists()


def test_rule_without_a_share_uses_the_default_one(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n", shares=shares)
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (second / "rechnungen").exists()


def test_unmounted_share_diverts_to_the_default_share(tmp_path):
    """A NAS that is down must not turn its mount point into a local folder."""
    gone = tmp_path / "nicht-gemountet"
    shares = ShareSet(
        [Share(id="nas1", path=str(tmp_path)), Share(id="weg", path=str(gone))],
        fallback_root=str(tmp_path),
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: weg
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not gone.exists()
    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_quarantine_stays_on_the_share_the_rule_named(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: nas2
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "quarantaene").glob("*"))) == 1


# --- mail from a known device (scan-to-mail) ---------------------------------


def _scan_message(sender: str, subject: str, filename: str = "SKM_C250i.pdf") -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg.set_content("Scan")
    msg.add_attachment(b"scan", maintype="application", subtype="pdf", filename=filename)
    return bytes(msg)


def test_device_with_a_fixed_folder_beats_a_keyword_in_the_subject(tmp_path):
    """A scanner's subject line is boilerplate - it must not steer the filing."""
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, mapping_content="Scan: irgendwo\n", printers=[printer])
    raw = _scan_message("scanner@example.com", "Scan vom Kopierer")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "scans").glob("*"))) == 1
    assert not (tmp_path / "irgendwo").exists()


def test_device_without_a_fixed_folder_leaves_the_rules_in_charge(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com")
    archiver = _make_archiver(tmp_path, mapping_content="Rechnung: rechnungen\n", printers=[printer])
    raw = _scan_message("scanner@example.com", "Rechnung 4711")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_mail_from_someone_else_is_not_treated_as_a_device(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, mapping_content="Rechnung: rechnungen\n", printers=[printer])
    raw = _scan_message("lieferant@example.com", "Rechnung 4711")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "scans").exists()


def test_device_can_file_onto_another_nas(tmp_path):
    shares, second = _two_share_set(tmp_path)
    printer = Printer(
        id="kopierer", sender="scanner@example.com", target_share="nas2", target_folder="scans"
    )
    archiver = _make_archiver(tmp_path, printers=[printer], shares=shares)
    raw = _scan_message("scanner@example.com", "Scan")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "scans").glob("*"))) == 1


def test_blocked_extension_from_a_device_is_still_quarantined(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, printers=[printer])
    raw = _scan_message("scanner@example.com", "Scan", filename="scan.exe")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
    assert not (tmp_path / "scans").exists()


# --- encoded filenames -------------------------------------------------------


def test_keyword_in_an_rfc2047_encoded_filename_is_found(tmp_path):
    """Mail clients encode non-ASCII filenames - the keyword is in there too."""
    archiver = _make_archiver(tmp_path, mapping_content="Angebot: angebote\n")
    msg = EmailMessage()
    msg["Subject"] = "ohne Stichwort"
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    msg.add_attachment(
        b"DATA",
        maintype="application",
        subtype="pdf",
        filename=("utf-8", "", "Angebot_Grün.pdf"),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=bytes(msg)), 1)

    assert len(list((tmp_path / "angebote").glob("*"))) == 1


def test_unusable_quarantine_folder_never_lands_in_a_business_folder(tmp_path):
    """A broken quarantine path must not put an .exe next to the invoices."""
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", quarantine_folder="../raus"
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path / "rechnungen").exists()
    assert not (tmp_path / "unsorted").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
