from __future__ import annotations

import email
import hashlib
import logging
from dataclasses import dataclass
from datetime import date, timedelta
from email.header import decode_header, make_header
from email.message import Message
from email.parser import BytesHeaderParser
from email.utils import getaddresses, parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .accounts import Account
from .addresses import AddressRule, AddressStore
from .archives import StorageSet
from .filenames import extension_of, safe_relative_parts, sanitize_filename
from . import journal as j
from .mapping import Mapping, Rule
from .options import Options
from .printers import Printer
from .printing import PrintService, job_title
from .state import ProcessedStore

logger = logging.getLogger(__name__)

# Where the address a mail was actually delivered to can be found. The
# envelope headers come first: an alias like "drucker@firma.de" is usually
# delivered into a shared mailbox, and then only the delivery headers still
# name the alias - To: may say something else entirely (or nothing, for Bcc).
RECIPIENT_HEADERS = (
    "Delivered-To",
    "X-Original-To",
    "Envelope-To",
    "X-Envelope-To",
    "X-RcptTo",
    "To",
    "Cc",
    "Resent-To",
    "X-Forwarded-To",
)
# A mail may legitimately carry a few dozen recipients; thousands are either a
# mistake or an attempt to make matching expensive.
MAX_RECIPIENTS = 50
# Seconds a single IMAP command may take. Without a timeout a server that
# stops answering mid-session blocks the worker forever - no error, no retry.
IMAP_TIMEOUT = 60
# Asked for before the whole message: enough to recognise a mail that was
# already processed, without downloading it again. PEEK, so asking does not
# mark anything as read.
HEADER_PART = "BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]"
# The processed-message list is pruned after the retention period. A mailbox
# that also processes read mail must therefore never look back that far, or a
# forgotten mail still sitting in the folder would be filed a second time. The
# margin covers the time between a mail's arrival and its processing.
SEEN_WINDOW_MARGIN_DAYS = 2


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def recipients_of(msg: Message) -> list[str]:
    """Every address this message was addressed or delivered to, lowercased."""
    found: list[str] = []
    seen: set[str] = set()
    for header in RECIPIENT_HEADERS:
        for raw in msg.get_all(header, []):
            for _, address in getaddresses([_decode(raw)]):
                address = address.strip().lower()
                if not address or address in seen:
                    continue
                seen.add(address)
                found.append(address)
                if len(found) >= MAX_RECIPIENTS:
                    logger.warning(
                        "Message has more than %d recipients - only those are matched",
                        MAX_RECIPIENTS,
                    )
                    return found
    return found


def _message_id(msg: Message, uid: int, account_key: str) -> str:
    """Idempotency key. Scoped per account: the same message delivered to two
    watched mailboxes is two things to archive, not one."""
    return f"{account_key}:" + (msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>")


def part_key(index: int, payload: bytes) -> str:
    """Identifies one attachment of a mail for the retry check: its position
    and its content, so a different file at the same position never counts
    as already done."""
    return f"{index}:{hashlib.sha256(payload).hexdigest()[:20]}"


def _header_part(entry: dict) -> bytes | None:
    """The fetched Message-ID header, or None if the server did not send it.

    Servers echo the section name in different spellings, so the key is
    found by its prefix rather than by an exact match.
    """
    for key, value in entry.items():
        name = key.decode("ascii", "replace") if isinstance(key, bytes) else str(key)
        if name.upper().startswith("BODY[HEADER"):
            return value or b""
    return None


@dataclass(frozen=True)
class AttachmentPlan:
    """What is to happen with one attachment, decided before anything happens.

    Filing and printing are two independent answers to the same question, and
    both depend on the same rule match - so they are worked out together and
    then carried out, rather than being re-derived at each step.
    """

    folder: str
    keyword: str | None
    quarantined: bool
    archive: bool
    printer: Printer | None
    address: AddressRule | None = None
    # Which archive the folder is on; "" = the default one. Not to be confused
    # with `archive` above, which says *whether* to file at all.
    archive_key: str = ""


class Archiver:
    def __init__(
        self,
        options,
        mapping: Mapping,
        store: ProcessedStore,
        storages,
        account: Account,
        printing: PrintService | None = None,
        addresses: AddressStore | None = None,
        journal=None,
    ):
        # `options` is an Options snapshot or a callable returning the current
        # one. The callable is what the service uses: the settings page takes
        # effect on the next message, without restarting the worker.
        self._options = options
        self.mapping = mapping
        self.store = store
        # A StorageSet (one storage per archive), or a single Storage for an
        # installation - or a test - with exactly one place to file into.
        self.storages = storages
        self.account = account
        self.printing = printing
        # Optional, like `printing`: an installation without address rules
        # behaves exactly as before.
        self.addresses = addresses
        # What happened to each attachment; also what makes a retry skip the
        # attachments that were already filed or printed. Optional for tests.
        self.journal = journal
        # UIDs known to be processed in the current IMAP session, so a mailbox
        # that also looks at read mail does not ask about them every cycle.
        self._done_uids: set[int] = set()
        # Failures already written to the journal in this session - a mail
        # that keeps failing is recorded once, not on every retry.
        self._reported: set[tuple[int, str]] = set()

    @property
    def options(self) -> Options:
        return self._options() if callable(self._options) else self._options

    @property
    def blocked_extensions(self) -> frozenset[str]:
        return self.options.blocked_extensions

    def storage_for(self, archive_key: str):
        """The archive a plan points at, or the only one there is."""
        if isinstance(self.storages, StorageSet):
            return self.storages.get(archive_key)
        return self.storages

    def connect(self) -> IMAPClient:
        client = IMAPClient(
            self.account.host, port=self.account.port, ssl=self.account.ssl, timeout=IMAP_TIMEOUT
        )
        client.login(self.account.user, self.account.password)
        client.select_folder(self.account.folder)
        # UIDs are only meaningful within one session (UIDVALIDITY).
        self._done_uids.clear()
        self._reported.clear()
        return client

    @property
    def source(self) -> str:
        """How this mailbox is named in the journal."""
        return f"Postfach {self.account.name}"

    def _record(self, action: str, **fields) -> None:
        if self.journal is not None:
            self.journal.record(self.source, action, **fields)

    def seen_since(self, today: date | None = None) -> date:
        """The oldest arrival date considered when read mail is included."""
        today = today or date.today()
        retention = getattr(self.options, "retention_days", j.DEFAULT_RETENTION_DAYS)
        earliest = today - timedelta(days=max(1, retention - SEEN_WINDOW_MARGIN_DAYS))
        try:
            wanted = date.fromisoformat(self.account.seen_since) if self.account.seen_since else today
        except ValueError:
            wanted = today
        return max(wanted, earliest)

    def search_criteria(self, today: date | None = None) -> list:
        """What to ask the server for: unread mail, and - if the mailbox is set
        to - read mail since the configured date as well."""
        if not self.account.include_seen:
            return ["UNSEEN"]
        return ["OR", "UNSEEN", "SINCE", self.seen_since(today)]

    def _match(self, *texts: str) -> Rule | None:
        # Rules can be limited to a single mailbox, so the account has to be
        # part of every lookup.
        return self.mapping.match(*texts, account_id=self.account.key)

    def run_once(self, client: IMAPClient) -> int:
        """Process all currently unseen messages. Returns the number processed."""
        self.mapping.reload()
        uids = [uid for uid in client.search(self.search_criteria()) if uid not in self._done_uids]
        if not uids:
            return 0

        processed = 0
        for uid in uids:
            try:
                if self._process_message(client, uid):
                    processed += 1
            except Exception as exc:
                logger.exception("Failed to process message UID %s, leaving it for retry", uid)
                reason = f"{exc.__class__.__name__}: {exc}"
                if (uid, reason) not in self._reported:
                    self._reported.add((uid, reason))
                    self._record(
                        j.FAILED,
                        message_key=f"uid:{uid}",
                        detail=f"Mail (UID {uid}) nicht verarbeitet, wird erneut versucht - {reason}",
                    )
        return processed

    def _already_processed(self, client: IMAPClient, uid: int, entry: dict) -> bool:
        """Recognise a processed mail from its header alone.

        Returns False when that is not possible (the server did not return the
        header) - the full message is then fetched and checked as before.
        """
        header = _header_part(entry)
        if header is None:
            return False
        parsed = BytesHeaderParser().parsebytes(header)
        message_id = _message_id(parsed, uid, self.account.key)
        if not self.store.is_processed(message_id):
            return False
        self._done_uids.add(uid)
        flags = entry.get(b"FLAGS") or ()
        if b"\\Seen" not in flags and not self.options.dry_run:
            logger.info("UID %s (%s) already processed, marking seen", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
        return True

    def _process_message(self, client: IMAPClient, uid: int) -> bool:
        # Check the message size *before* pulling the full body into memory -
        # a hostile/broken sender could otherwise use an oversized message to
        # exhaust memory/disk on every poll cycle.
        head = client.fetch([uid], ["RFC822.SIZE", "FLAGS", HEADER_PART]).get(uid, {})
        if self._already_processed(client, uid, head):
            return False
        message_size = head.get(b"RFC822.SIZE", 0)
        max_message_bytes = self.options.max_message_size_mb * 1024 * 1024
        if message_size and message_size > max_message_bytes:
            logger.warning(
                "UID %s is %.1f MB, exceeds MAX_MESSAGE_SIZE_MB=%d - skipping attachment "
                "extraction and flagging for manual review",
                uid,
                message_size / (1024 * 1024),
                self.options.max_message_size_mb,
            )
            if not self.options.dry_run:
                self._record(
                    j.TOO_LARGE,
                    message_key=f"uid:{uid}",
                    detail=(
                        f"Mail ist {message_size / (1024 * 1024):.1f} MB gross, erlaubt sind "
                        f"{self.options.max_message_size_mb} MB - nicht verarbeitet"
                        + (f", verschoben nach {self.account.oversized_folder}"
                           if self.account.oversized_folder else "")
                    ),
                )
                client.add_flags([uid], [b"\\Seen"])
                if self.account.oversized_folder:
                    client.move([uid], self.account.oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid, self.account.key)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            self._done_uids.add(uid)
            if not self.options.dry_run:
                client.add_flags([uid], [b"\\Seen"])
            return False

        subject = _decode(msg.get("Subject"))
        _, sender_addr = parseaddr(_decode(msg.get("From")))
        body = self._extract_body(msg) if self.options.match_body else ""
        mail_rule = self._match(subject, body)
        address_rule = self._address_rule(msg, sender_addr)
        if address_rule is not None:
            logger.info(
                "UID %s '%s' is addressed to %s (%s)",
                uid,
                subject,
                address_rule.recipient or address_rule.sender,
                address_rule.name,
            )

        attachments = list(self._iter_attachments(msg))
        if len(attachments) > self.options.max_attachments_per_message:
            logger.warning(
                "UID %s '%s' has %d attachments, only processing the first %d "
                "(MAX_ATTACHMENTS_PER_MESSAGE)",
                uid,
                subject,
                len(attachments),
                self.options.max_attachments_per_message,
            )
            attachments = attachments[: self.options.max_attachments_per_message]

        saved: list[str] = []
        context = dict(message_key=message_id, subject=subject, sender=sender_addr)
        if not attachments:
            logger.info("UID %s '%s' has no attachments, nothing to save", uid, subject)
            if not self.options.dry_run:
                self._record(j.NO_ATTACHMENTS, **context)
        else:
            date_prefix = self._date_prefix(msg)
            max_attachment_bytes = self.options.max_attachment_size_mb * 1024 * 1024
            for index, (filename, payload) in enumerate(attachments):
                shown = sanitize_filename(_decode(filename))
                if len(payload) > max_attachment_bytes:
                    logger.warning(
                        "UID %s '%s': attachment '%s' is %.1f MB, exceeds "
                        "MAX_ATTACHMENT_SIZE_MB=%d - skipping this attachment",
                        uid,
                        subject,
                        filename,
                        len(payload) / (1024 * 1024),
                        self.options.max_attachment_size_mb,
                    )
                    if not self.options.dry_run:
                        self._record(
                            j.SKIPPED, filename=shown, **context,
                            detail=(f"Anhang ist {len(payload) / (1024 * 1024):.1f} MB gross, "
                                    f"erlaubt sind {self.options.max_attachment_size_mb} MB"),
                        )
                    continue

                part = part_key(index, payload)
                plan = self._plan_attachment(filename, mail_rule, address_rule)
                out_name = self._build_filename(date_prefix, sender_addr, filename)
                item = dict(context, part_key=part, filename=shown)

                # A retry of a mail that failed half-way: what already happened
                # to this attachment is not done a second time.
                already_filed = self._done(message_id, part, j.FILED_ACTIONS)
                already_printed = self._done(message_id, part, (j.PRINTED,))

                if plan.archive:
                    if already_filed:
                        logger.info("UID %s: attachment '%s' was already filed, skipping",
                                    uid, filename)
                    else:
                        self._file(plan, out_name, payload, uid, subject, filename, saved, item)

                # Printing comes after filing, deliberately: the share is the
                # archive and paper is the copy, so a printer that is offline
                # or out of paper must never be the reason an attachment was
                # not stored.
                printed = already_printed
                if plan.printer is not None and not already_printed:
                    printed = self._print(plan, payload, out_name, subject, filename, item)

                if not plan.archive and not printed:
                    # "Print only" and yet nothing came out - no printer, a
                    # format it cannot print, CUPS down. The mail is marked as
                    # read in a moment, so this is the last chance to keep the
                    # attachment: file it after all rather than lose it.
                    logger.warning(
                        "UID %s '%s': attachment '%s' was meant to be printed only, but "
                        "nothing was printed - filing it instead so it is not lost",
                        uid,
                        subject,
                        filename,
                    )
                    if not already_filed:
                        self._file(plan, out_name, payload, uid, subject, filename, saved, item)
                elif not plan.archive:
                    logger.info(
                        "UID %s '%s': attachment '%s' printed, not archived (%s)",
                        uid,
                        subject,
                        filename,
                        f"address rule {plan.address.name!r}"
                        if plan.address is not None
                        else "mailbox set to print only",
                    )

        if not self.options.dry_run:
            self.store.mark_processed(message_id)
            self._done_uids.add(uid)
            client.add_flags([uid], [b"\\Seen"])
            if self.account.processed_folder:
                client.move([uid], self.account.processed_folder)
        return True

    def _done(self, message_key: str, part: str, actions) -> bool:
        if self.journal is None or self.options.dry_run:
            return False
        try:
            return self.journal.done(message_key, part, actions)
        except Exception:  # noqa: BLE001 - better a duplicate than a lost attachment
            logger.exception("Could not read the journal - processing the attachment again")
            return False

    def _print(self, plan, payload, out_name, subject, filename, item) -> bool:
        # The spooler knows about the test mode itself and only logs then.
        printed = self.printing.send(plan.printer, payload, out_name, job_title(subject, filename))
        if self.options.dry_run:
            self._record(j.DRY_RUN, target=plan.printer.label(), detail="wuerde gedruckt", **item)
        elif printed:
            self._record(j.PRINTED, target=plan.printer.label(), **item)
        else:
            self._record(
                j.NOT_PRINTED, target=plan.printer.label(), **item,
                detail="Druckauftrag nicht angenommen oder Dateityp nicht druckbar - "
                       "Details im Protokoll",
            )
        return printed

    def _file(self, plan, out_name, payload, uid, subject, filename, saved, item=None) -> None:
        target_parts = self._target_parts(plan.folder)
        storage = self.storage_for(plan.archive_key)
        if self.options.dry_run:
            logger.info("[dry-run] would save %s -> %s", out_name, storage.display(target_parts))
            self._record(j.DRY_RUN, target=storage.display(target_parts, out_name),
                         detail="wuerde abgelegt", **(item or {}))
            return
        out_path = storage.save_unique(target_parts, out_name, payload)
        saved.append(out_path)
        self._record(
            j.QUARANTINED if plan.quarantined else j.FILED,
            target=out_path,
            detail=("gesperrte Dateiendung" if plan.quarantined
                    else f"Stichwort {plan.keyword}" if plan.keyword
                    else f"Adresse {plan.address.name}" if plan.address is not None
                    else "kein Treffer - Fallback-Ordner"),
            **(item or {}),
        )
        logger.info(
            "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
            uid,
            subject,
            filename,
            plan.keyword or "<fallback>",
            " [QUARANTAENE: gesperrte Dateiendung]" if plan.quarantined else "",
            out_path,
        )

    def _target_parts(self, folder_name: str) -> tuple[str, ...]:
        """Map a configured folder name onto path components inside the archive root.

        Folder names come from rules and address entries - and a rule file
        imported from somewhere else is not necessarily trustworthy; anything that would escape the archive root is rejected and
        replaced with the fallback folder rather than being written outside.
        """
        for candidate, note in ((folder_name, None), (self.options.fallback_folder, "fallback"), ("unsorted", "built-in")):
            try:
                target = safe_relative_parts(candidate)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the archive root", candidate, exc
                )
                continue
            if note and candidate != folder_name:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder_name)
            return target
        raise ValueError("No usable target folder inside the archive root")

    def _address_rule(self, msg: Message, sender_addr: str) -> AddressRule | None:
        """The configured address this mail was sent to, if any."""
        if self.addresses is None:
            return None
        try:
            return self.addresses.match(recipients_of(msg), sender_addr)
        except Exception:
            # Routing is a convenience; a broken lookup must not stop the mail
            # from being archived the ordinary way.
            logger.exception("Could not match the delivery address - continuing without it")
            return None

    def _plan_attachment(
        self, filename: str, mail_rule: Rule | None, address_rule: AddressRule | None = None
    ) -> AttachmentPlan:
        """Decide where a single attachment is filed, and whether it is printed.

        The attachment's own filename is checked against the mapping first,
        so multiple differently-named attachments on the same mail can land
        in different folders. Falls back to the mail-level (subject/body)
        match when the filename itself gives no hint. Attachments with a
        blocked extension are always quarantined, regardless of any keyword
        match, so a malicious/executable attachment can never be renamed
        into a trusted-looking business folder just by naming it "Rechnung.exe".

        An address rule outranks both. Somebody who sends a document to
        `drucker-buero@firma.de` has said what should happen with it more
        clearly than any keyword can; the keywords then only still decide the
        folder, and only if the address rule names none.
        """
        rule = self._match(filename) or mail_rule

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(filename), extension_of(sanitize_filename(_decode(filename)))}
        quarantined = bool(extensions & self.blocked_extensions)

        return AttachmentPlan(
            folder=self.options.quarantine_folder if quarantined else self._folder_of(rule, address_rule),
            keyword=rule.keyword if rule else None,
            quarantined=quarantined,
            archive_key=self._archive_of(rule, address_rule),
            # "Print only" still files anything quarantined: it cannot be
            # printed either, and dropping it without a trace would hide
            # exactly the attachment somebody may need to look at.
            archive=self._archives(address_rule) or quarantined,
            printer=self._printer_for(rule, quarantined, address_rule),
            address=address_rule,
        )

    def _archives(self, address_rule: AddressRule | None) -> bool:
        if address_rule is not None:
            return address_rule.archive_attachments
        return self.account.archive_attachments

    def _folder_of(self, rule: Rule | None, address_rule: AddressRule | None = None) -> str:
        if address_rule is not None and address_rule.folder:
            return address_rule.folder
        return rule.folder if rule else self.options.fallback_folder

    def _archive_of(self, rule: Rule | None, address_rule: AddressRule | None = None) -> str:
        """Which archive the folder lives on.

        An address rule that names one wins - it is the more specific
        statement, even when the folder itself comes from a keyword rule
        ("file it where it usually goes, but on that NAS").
        """
        if address_rule is not None and address_rule.archive:
            return address_rule.archive
        return rule.archive if rule else ""

    def _printer_for(
        self, rule: Rule | None, quarantined: bool, address_rule: AddressRule | None = None
    ) -> Printer | None:
        """Which printer this attachment goes to, if any.

        Printing is requested by the address it was sent to ("everything for
        drucker-buero@ goes on the office printer"), by the mailbox ("print
        everything that arrives here") or by the matched rule ("print
        invoices"). The printer is then the most specific one configured:
        address before rule before mailbox.

        A matching address rule also has the last word on *whether* to print.
        Its whole purpose is to say what happens to mail sent there, so an
        address set to "only file" is not overruled by a keyword rule.
        """
        if self.printing is None or not self.options.printing_enabled:
            return None
        if quarantined:
            # A blocked attachment is a suspected executable. It is neither
            # printable nor something to hand to a printer driver.
            return None

        by_rule = rule is not None and rule.print_attachments
        if address_rule is not None:
            if not address_rule.print_attachments:
                return None
            keys = (address_rule.printer, rule.printer if by_rule else "", self.account.printer)
            wanted_by = f"address {address_rule.name!r}"
        else:
            if not (self.account.print_attachments or by_rule):
                return None
            keys = (rule.printer if by_rule else "", self.account.printer)
            wanted_by = f"rule {rule.keyword!r}" if by_rule else f"mailbox {self.account.name!r}"

        printer = self.printing.printer_for(*keys)
        if printer is None:
            logger.warning(
                "Printing is enabled for %s but no usable printer is configured - "
                "nothing was printed",
                wanted_by,
            )
        return printer

    @staticmethod
    def _date_prefix(msg: Message) -> str:
        date_header = msg.get("Date")
        if date_header:
            try:
                return parsedate_to_datetime(date_header).strftime("%Y-%m-%d")
            except (TypeError, ValueError):
                pass
        return "unknown-date"

    def _build_filename(self, date_prefix: str, sender_addr: str, filename: str) -> str:
        filename = sanitize_filename(_decode(filename))
        mode = self.options.filename_prefix
        if mode == "none":
            return filename
        if mode == "date":
            return f"{date_prefix}_{filename}"
        sender = sanitize_filename(sender_addr or "unknown")
        if mode == "sender":
            return f"{sender}_{filename}"
        return f"{date_prefix}_{sender}_{filename}"

    @staticmethod
    def _iter_attachments(msg: Message):
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            disposition = part.get_content_disposition()
            filename = part.get_filename()
            if disposition != "attachment" and not filename:
                continue
            payload = part.get_payload(decode=True)
            if payload is None:
                continue
            yield filename or "attachment", payload

    @staticmethod
    def _extract_body(msg: Message) -> str:
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain" and not part.get_filename():
                    try:
                        return part.get_payload(decode=True).decode(
                            part.get_content_charset() or "utf-8", errors="replace"
                        )
                    except Exception:
                        continue
            return ""
        try:
            return msg.get_payload(decode=True).decode(msg.get_content_charset() or "utf-8", errors="replace")
        except Exception:
            return ""
