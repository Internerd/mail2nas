from __future__ import annotations

import email
import logging
from dataclasses import dataclass
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .accounts import Account
from .config import Config
from .filenames import extension_of, safe_relative_parts, sanitize_filename
from .mapping import Mapping, Rule
from .printers import Printer
from .printing import PrintService, job_title
from .state import ProcessedStore
from .storage import Storage

logger = logging.getLogger(__name__)


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def _message_id(msg: Message, uid: int, account_key: str) -> str:
    """Idempotency key. Scoped per account: the same message delivered to two
    watched mailboxes is two things to archive, not one."""
    return f"{account_key}:" + (msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>")


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


class Archiver:
    def __init__(
        self,
        config: Config,
        mapping: Mapping,
        store: ProcessedStore,
        storage: Storage,
        account: Account,
        printing: PrintService | None = None,
    ):
        self.config = config
        self.mapping = mapping
        self.store = store
        self.storage = storage
        self.account = account
        self.printing = printing

    def connect(self) -> IMAPClient:
        client = IMAPClient(self.account.host, port=self.account.port, ssl=self.account.ssl)
        client.login(self.account.user, self.account.password)
        client.select_folder(self.account.folder)
        return client

    def _match(self, *texts: str) -> Rule | None:
        # Rules can be limited to a single mailbox, so the account has to be
        # part of every lookup.
        return self.mapping.match(*texts, account_id=self.account.key)

    def run_once(self, client: IMAPClient) -> int:
        """Process all currently unseen messages. Returns the number processed."""
        self.mapping.reload()
        uids = client.search(["UNSEEN"])
        if not uids:
            return 0

        processed = 0
        for uid in uids:
            try:
                if self._process_message(client, uid):
                    processed += 1
            except Exception:
                logger.exception("Failed to process message UID %s, leaving it for retry", uid)
        return processed

    def _process_message(self, client: IMAPClient, uid: int) -> bool:
        # Check the message size *before* pulling the full body into memory -
        # a hostile/broken sender could otherwise use an oversized message to
        # exhaust memory/disk on every poll cycle.
        size_reply = client.fetch([uid], ["RFC822.SIZE"])
        message_size = size_reply.get(uid, {}).get(b"RFC822.SIZE", 0)
        max_message_bytes = self.config.max_message_size_mb * 1024 * 1024
        if message_size and message_size > max_message_bytes:
            logger.warning(
                "UID %s is %.1f MB, exceeds MAX_MESSAGE_SIZE_MB=%d - skipping attachment "
                "extraction and flagging for manual review",
                uid,
                message_size / (1024 * 1024),
                self.config.max_message_size_mb,
            )
            if not self.config.dry_run:
                client.add_flags([uid], [b"\\Seen"])
                if self.account.oversized_folder:
                    client.move([uid], self.account.oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid, self.account.key)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
            return False

        subject = _decode(msg.get("Subject"))
        _, sender_addr = parseaddr(_decode(msg.get("From")))
        body = self._extract_body(msg) if self.config.match_body else ""
        mail_rule = self._match(subject, body)

        attachments = list(self._iter_attachments(msg))
        if len(attachments) > self.config.max_attachments_per_message:
            logger.warning(
                "UID %s '%s' has %d attachments, only processing the first %d "
                "(MAX_ATTACHMENTS_PER_MESSAGE)",
                uid,
                subject,
                len(attachments),
                self.config.max_attachments_per_message,
            )
            attachments = attachments[: self.config.max_attachments_per_message]

        saved: list[str] = []
        if not attachments:
            logger.info("UID %s '%s' has no attachments, nothing to save", uid, subject)
        else:
            date_prefix = self._date_prefix(msg)
            max_attachment_bytes = self.config.max_attachment_size_mb * 1024 * 1024
            for filename, payload in attachments:
                if len(payload) > max_attachment_bytes:
                    logger.warning(
                        "UID %s '%s': attachment '%s' is %.1f MB, exceeds "
                        "MAX_ATTACHMENT_SIZE_MB=%d - skipping this attachment",
                        uid,
                        subject,
                        filename,
                        len(payload) / (1024 * 1024),
                        self.config.max_attachment_size_mb,
                    )
                    continue

                plan = self._plan_attachment(filename, mail_rule)
                out_name = self._build_filename(date_prefix, sender_addr, filename)

                if plan.archive:
                    target_parts = self._target_parts(plan.folder)
                    if self.config.dry_run:
                        logger.info(
                            "[dry-run] would save %s -> %s",
                            out_name,
                            self.storage.display(target_parts),
                        )
                    else:
                        out_path = self.storage.save_unique(target_parts, out_name, payload)
                        saved.append(out_path)
                        logger.info(
                            "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
                            uid,
                            subject,
                            filename,
                            plan.keyword or "<fallback>",
                            " [QUARANTAENE: gesperrte Dateiendung]" if plan.quarantined else "",
                            out_path,
                        )
                elif plan.printer is not None:
                    logger.info(
                        "UID %s '%s': attachment '%s' is printed only, not archived",
                        uid,
                        subject,
                        filename,
                    )
                else:
                    # Neither filed nor printed - that is a configuration
                    # mistake rather than an intention, and the attachment is
                    # gone once the mail is marked as read.
                    logger.warning(
                        "UID %s '%s': attachment '%s' was neither archived nor printed - "
                        "the mailbox is set to print only but nothing prints it",
                        uid,
                        subject,
                        filename,
                    )

                # Printing comes after filing, deliberately: the share is the
                # archive and paper is the copy, so a printer that is offline
                # or out of paper must never be the reason an attachment was
                # not stored.
                if plan.printer is not None:
                    self.printing.send(
                        plan.printer, payload, out_name, job_title(subject, filename)
                    )

        if not self.config.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.account.processed_folder:
                client.move([uid], self.account.processed_folder)
        return True

    def _target_parts(self, folder_name: str) -> tuple[str, ...]:
        """Map a configured folder name onto path components inside the archive root.

        Folder names come from mapping.yaml on the share and are therefore
        untrusted; anything that would escape the archive root is rejected and
        replaced with the fallback folder rather than being written outside.
        """
        for candidate, note in ((folder_name, None), (self.config.fallback_folder, "fallback"), ("unsorted", "built-in")):
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

    def _plan_attachment(self, filename: str, mail_rule: Rule | None) -> AttachmentPlan:
        """Decide where a single attachment is filed, and whether it is printed.

        The attachment's own filename is checked against the mapping first,
        so multiple differently-named attachments on the same mail can land
        in different folders. Falls back to the mail-level (subject/body)
        match when the filename itself gives no hint. Attachments with a
        blocked extension are always quarantined, regardless of any keyword
        match, so a malicious/executable attachment can never be renamed
        into a trusted-looking business folder just by naming it "Rechnung.exe".
        """
        rule = self._match(filename) or mail_rule

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(filename), extension_of(sanitize_filename(_decode(filename)))}
        quarantined = bool(extensions & self.config.blocked_extensions)

        return AttachmentPlan(
            folder=self.config.quarantine_folder if quarantined else self._folder_of(rule),
            keyword=rule.keyword if rule else None,
            quarantined=quarantined,
            # "Print only" still files anything quarantined: it cannot be
            # printed either, and dropping it without a trace would hide
            # exactly the attachment somebody may need to look at.
            archive=self.account.archive_attachments or quarantined,
            printer=self._printer_for(rule, quarantined),
        )

    def _folder_of(self, rule: Rule | None) -> str:
        return rule.folder if rule else self.config.fallback_folder

    def _printer_for(self, rule: Rule | None, quarantined: bool) -> Printer | None:
        """Which printer this attachment goes to, if any.

        Printing is requested either by the mailbox ("print everything that
        arrives here") or by the matched rule ("print invoices"). The printer
        is then the most specific one configured: the rule's own choice beats
        the mailbox default.
        """
        if self.printing is None or not self.config.printing_enabled:
            return None
        if quarantined:
            # A blocked attachment is a suspected executable. It is neither
            # printable nor something to hand to a printer driver.
            return None

        by_rule = rule is not None and rule.print_attachments
        if not (self.account.print_attachments or by_rule):
            return None

        printer = self.printing.printer_for(
            rule.printer if by_rule else "", self.account.printer
        )
        if printer is None:
            logger.warning(
                "Printing is enabled for %s but no usable printer is configured - "
                "nothing was printed",
                f"rule {rule.keyword!r}" if by_rule else f"mailbox {self.account.name!r}",
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
        mode = self.config.filename_prefix
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
