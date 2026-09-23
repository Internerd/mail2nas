"""The processing journal, the stored log, pruning - and what the archiver
does with them: retries without duplicates, read mail per mailbox."""
from __future__ import annotations

import logging
import sqlite3
from datetime import date, datetime, timedelta, timezone

from mail2nas import journal as j
from mail2nas.accounts import AccountStore
from mail2nas.archiver import HEADER_PART
from mail2nas.journal import DatabaseLogHandler, Journal, LogStore
from mail2nas.state import ProcessedStore
from mail2nas.storage import LocalStorage
from tests.test_archiver import (
    FakeIMAPClient,
    _account,
    _build_message,
    _make_archiver,
    _make_printing,
    _make_runtime,
)


def _journal(tmp_path) -> Journal:
    return Journal(str(tmp_path / "state.db"))


# --- the journal itself -----------------------------------------------------------


def test_journal_records_and_filters(tmp_path):
    journal = _journal(tmp_path)
    journal.record("Postfach A", j.FILED, subject="Rechnung 1", filename="r.pdf", target="/x/r.pdf")
    journal.record("Postfach B", j.NOT_PRINTED, subject="Lieferschein", filename="l.pdf")

    assert journal.count() == 2
    assert [e.subject for e in journal.entries()] == ["Lieferschein", "Rechnung 1"]
    assert [e.source for e in journal.entries(problems_only=True)] == ["Postfach B"]
    assert [e.filename for e in journal.entries(search="rechn")] == ["r.pdf"]
    assert journal.count(source="Postfach A") == 1
    assert journal.sources() == ["Postfach A", "Postfach B"]


def test_journal_search_treats_wildcards_literally(tmp_path):
    journal = _journal(tmp_path)
    journal.record("A", j.FILED, subject="100% sicher")
    journal.record("A", j.FILED, subject="1000 sicher")

    assert [e.subject for e in journal.entries(search="100%")] == ["100% sicher"]


def test_journal_knows_what_was_done_to_an_attachment(tmp_path):
    journal = _journal(tmp_path)
    journal.record("A", j.FILED, message_key="1:<m@x>", part_key="0:abc")

    assert journal.done("1:<m@x>", "0:abc", j.FILED_ACTIONS)
    assert not journal.done("1:<m@x>", "0:abc", (j.PRINTED,))
    assert not journal.done("1:<m@x>", "1:abc", j.FILED_ACTIONS)
    assert not journal.done("", "", j.FILED_ACTIONS)


def test_entries_after_an_id_come_oldest_first(tmp_path):
    journal = _journal(tmp_path)
    first = journal.last_id()
    journal.record("A", j.FAILED, detail="eins")
    journal.record("A", j.FILED, detail="ok")
    journal.record("A", j.NOT_PRINTED, detail="zwei")

    new = journal.entries(after_id=first, problems_only=True, oldest_first=True)
    assert [e.detail for e in new] == ["eins", "zwei"]


def test_long_values_are_clipped(tmp_path):
    journal = _journal(tmp_path)
    journal.record("A", j.FAILED, detail="x" * 10_000)

    assert len(journal.entries()[0].detail) == j.MAX_MESSAGE


# --- the stored log -------------------------------------------------------------------


def test_log_handler_keeps_only_our_own_records(tmp_path):
    store = LogStore(str(tmp_path / "state.db"))
    handler = DatabaseLogHandler(store)
    ours = logging.getLogger("mail2nas.test_journal")
    theirs = logging.getLogger("smbprotocol.test_journal")
    for logger in (ours, theirs):
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
    try:
        ours.info("abgelegt %s", "a.pdf")
        ours.debug("zu viel Detail")
        theirs.warning("fremd")
        try:
            raise ValueError("kaputt")
        except ValueError:
            ours.exception("Fehler beim Abholen")
    finally:
        for logger in (ours, theirs):
            logger.removeHandler(handler)

    messages = [line.message for line in store.entries()]
    assert messages == ["Fehler beim Abholen - ValueError: kaputt", "abgelegt a.pdf"]
    assert [line.message for line in store.entries(min_level="ERROR")] == [messages[0]]
    assert store.count(search="abgelegt") == 1


# --- pruning -----------------------------------------------------------------------------


def test_prune_removes_old_entries_everywhere(tmp_path):
    runtime = _make_runtime(tmp_path)
    old = (datetime.now(timezone.utc) - timedelta(days=200)).strftime("%Y-%m-%d %H:%M:%S")
    runtime.journal.record("A", j.FILED, detail="neu")
    runtime.logs.add("INFO", "mail2nas", "neu")
    runtime.logs.add("INFO", "mail2nas", "alt", at=old)
    runtime.store.mark_processed("1:<neu@x>")
    with sqlite3.connect(runtime.config.state_db_path) as conn:
        conn.execute(
            "INSERT INTO journal (at, source, action, detail) VALUES (?, 'A', ?, 'alt')",
            (old, j.FILED),
        )
        conn.execute(
            "INSERT INTO processed_messages (message_id, processed_at) VALUES ('1:<alt@x>', ?)",
            (old,),
        )

    removed = j.prune(runtime, 183)

    assert removed == {"journal": 1, "log": 1, "processed": 1}
    assert [e.detail for e in runtime.journal.entries()] == ["neu"]
    assert runtime.store.is_processed("1:<neu@x>")
    assert not runtime.store.is_processed("1:<alt@x>")


def test_supervisor_prunes_with_the_configured_retention(tmp_path):
    from dataclasses import replace

    from mail2nas.main import Supervisor

    runtime = _make_runtime(tmp_path)
    runtime.set_options(replace(runtime.options, retention_days=30))
    old = (datetime.now(timezone.utc) - timedelta(days=40)).strftime("%Y-%m-%d %H:%M:%S")
    runtime.logs.add("INFO", "mail2nas", "alt", at=old)

    Supervisor(runtime, factory=lambda account: None)._maintenance()

    assert "alt" not in [line.message for line in runtime.logs.entries()]


# --- the archiver writes the journal ---------------------------------------------------


def _archiver_with_journal(tmp_path, **kwargs):
    archiver = _make_archiver(tmp_path, **kwargs)
    archiver.journal = _journal(tmp_path)
    return archiver


def test_filed_and_quarantined_attachments_are_journaled(tmp_path):
    archiver = _archiver_with_journal(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("Rechnung.pdf", b"PDF"), ("virus.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    entries = {e.filename: e for e in archiver.journal.entries()}
    assert entries["Rechnung.pdf"].action == j.FILED
    assert entries["Rechnung.pdf"].source == "Postfach Test"
    assert entries["Rechnung.pdf"].subject == "RE-1"
    assert entries["Rechnung.pdf"].detail == "Stichwort RE"
    assert "rechnungen" in entries["Rechnung.pdf"].target
    assert entries["virus.exe"].action == j.QUARANTINED


def test_mail_without_attachments_is_journaled(tmp_path):
    archiver = _archiver_with_journal(tmp_path)

    archiver._process_message(FakeIMAPClient(uid=1, raw=_build_message("Hallo", [])), 1)

    assert [e.action for e in archiver.journal.entries()] == [j.NO_ATTACHMENTS]


def test_dry_run_is_journaled_but_does_not_count_as_done(tmp_path):
    archiver = _archiver_with_journal(tmp_path, dry_run=True)
    raw = _build_message("RE-1", [("a.pdf", b"PDF")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    (entry,) = archiver.journal.entries()
    assert entry.action == j.DRY_RUN
    assert not archiver.journal.done(entry.message_key, entry.part_key, j.FILED_ACTIONS)


# --- retries do not duplicate -----------------------------------------------------------


class FailOnce(LocalStorage):
    """Fails the first time a file with `name` in it is saved."""

    def __init__(self, root, name):
        super().__init__(root)
        self.name = name
        self.failed = False

    def save_unique(self, parts, filename, data):
        if self.name in filename and not self.failed:
            self.failed = True
            raise OSError("NAS voll")
        return super().save_unique(parts, filename, data)


def test_a_retried_mail_does_not_file_its_first_attachment_twice(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _archiver_with_journal(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        storages=FailOnce(str(tmp_path), "zwei"),
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
    )
    raw = _build_message("RE-1", [("eins.pdf", b"ONE"), ("zwei.pdf", b"TWO")])

    try:
        archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)
    except OSError:
        pass
    else:
        raise AssertionError("the first attempt should have failed")
    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    names = sorted(path.name for path in (tmp_path / "rechnungen").iterdir())
    assert len(names) == 2
    assert any("eins" in name for name in names) and any("zwei" in name for name in names)
    printed = [filename for _, filename in spooler.jobs]
    assert len(printed) == 2
    assert sum("eins" in name for name in printed) == 1


def test_the_same_file_name_with_other_content_is_not_skipped(tmp_path):
    archiver = _archiver_with_journal(tmp_path, mapping_content="RE: rechnungen\n")

    archiver._process_message(
        FakeIMAPClient(uid=1, raw=_build_message("RE-1", [("a.pdf", b"ONE")])), 1
    )
    archiver._process_message(
        FakeIMAPClient(uid=2, raw=_build_message("RE-2", [("a.pdf", b"TWO")])), 2
    )

    assert len(list((tmp_path / "rechnungen").iterdir())) == 2


def test_a_failing_mail_is_journaled_once_per_session(tmp_path):
    archiver = _archiver_with_journal(tmp_path)

    class AlwaysFail(FakeIMAPClient):
        def search(self, criteria):
            return [9]

        def fetch(self, uids, parts):
            raise ConnectionError("weg")

    client = AlwaysFail(uid=9, raw=b"")
    archiver.run_once(client)
    archiver.run_once(client)

    (entry,) = archiver.journal.entries()
    assert entry.action == j.FAILED
    assert "ConnectionError: weg" in entry.detail


# --- recognising processed mail from the header ---------------------------------------


class HeaderClient(FakeIMAPClient):
    """Answers header fetches like a real server, and remembers what was asked."""

    def __init__(self, uid, raw, seen=False):
        super().__init__(uid, raw)
        self.requests: list[list[str]] = []
        self.seen = seen

    def search(self, criteria):
        self.criteria = criteria
        return [self._uid]

    def fetch(self, uids, parts):
        self.requests.append(list(parts))
        result = super().fetch(uids, parts)
        if HEADER_PART in parts:
            header = b"".join(
                line for line in self._raw.splitlines(keepends=True)
                if line.lower().startswith(b"message-id")
            )
            result[self._uid][b"BODY[HEADER.FIELDS (MESSAGE-ID)]"] = header + b"\r\n"
            result[self._uid][b"FLAGS"] = (b"\\Seen",) if self.seen else ()
        return result


def _with_id(subject, attachments, message_id="<fest@example.com>"):
    raw = _build_message(subject, attachments)
    return b"Message-ID: " + message_id.encode() + b"\r\n" + raw


def test_a_processed_mail_is_recognised_without_downloading_it(tmp_path):
    archiver = _archiver_with_journal(tmp_path)
    raw = _with_id("RE-1", [("a.pdf", b"PDF")])
    archiver._process_message(HeaderClient(1, raw), 1)

    again = HeaderClient(1, raw, seen=True)
    assert archiver.run_once(again) == 0

    assert all("RFC822" not in parts for parts in again.requests)
    assert again.flags_added == []


def test_a_processed_but_unread_mail_is_marked_read(tmp_path):
    archiver = _archiver_with_journal(tmp_path)
    raw = _with_id("RE-1", [("a.pdf", b"PDF")])
    ProcessedStore(str(tmp_path / "state.db")).mark_processed("1:<fest@example.com>")

    client = HeaderClient(1, raw, seen=False)
    archiver._process_message(client, 1)

    assert client.flags_added == [([1], [b"\\Seen"])]
    assert not (tmp_path / "unsorted").exists()


def test_known_uids_are_not_asked_about_again_in_the_same_session(tmp_path):
    archiver = _archiver_with_journal(tmp_path)
    raw = _with_id("RE-1", [("a.pdf", b"PDF")])
    client = HeaderClient(1, raw)

    archiver.run_once(client)
    requests = len(client.requests)
    archiver.run_once(client)

    assert len(client.requests) == requests


# --- read mail, per mailbox ----------------------------------------------------------------


def test_only_unread_mail_by_default(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver.search_criteria() == ["UNSEEN"]


def test_read_mail_since_the_configured_date(tmp_path):
    today = date(2026, 9, 23)
    archiver = _make_archiver(
        tmp_path, account=_account(include_seen=True, seen_since="2026-09-01")
    )

    assert archiver.search_criteria(today) == ["OR", "UNSEEN", "SINCE", date(2026, 9, 1)]


def test_read_mail_never_reaches_back_past_the_retention(tmp_path):
    today = date(2026, 9, 23)
    archiver = _make_archiver(
        tmp_path,
        account=_account(include_seen=True, seen_since="2020-01-01"),
        retention_days=100,
    )

    (_, _, _, since) = archiver.search_criteria(today)
    assert since == today - timedelta(days=100 - 2)


def test_accounts_store_the_read_mail_option(tmp_path):
    store = AccountStore(str(tmp_path / "state.db"))
    account_id = store.add(name="A", host="h", user="u", password="p", include_seen=True,
                           seen_since="2026-01-15")

    account = store.get(account_id)
    assert account.include_seen and account.seen_since == "2026-01-15"
    store.update(account_id, name="B")
    assert store.get(account_id).include_seen

    store.update(account_id, include_seen=True, seen_since="")
    assert store.get(account_id).seen_since == date.today().isoformat()


def test_an_older_account_table_gets_the_new_columns(tmp_path):
    path = str(tmp_path / "state.db")
    with sqlite3.connect(path) as conn:
        conn.execute(
            "CREATE TABLE imap_accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, "
            "host TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 993, ssl INTEGER NOT NULL DEFAULT 1, "
            "user TEXT NOT NULL, password TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'INBOX', "
            "mode TEXT NOT NULL DEFAULT 'poll', processed_folder TEXT NOT NULL DEFAULT '', "
            "oversized_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute("INSERT INTO imap_accounts (name, host, user, password) VALUES ('A','h','u','p')")

    (account,) = AccountStore(path).all()

    assert account.include_seen is False
    assert account.seen_since == ""
    assert account.archive_attachments is True
