from __future__ import annotations

import email
import logging
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .config import Config
from .filing import Filer, decode_mime_words
from .mapping import Mapping, Target
from .settings import Printer
from .shares import ShareSet
from .state import ProcessedStore

logger = logging.getLogger(__name__)


def _message_id(msg: Message, uid: int) -> str:
    return msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>"


class Archiver:
    def __init__(
        self,
        config: Config,
        mapping: Mapping,
        store: ProcessedStore,
        shares: ShareSet | None = None,
        printers: list[Printer] | None = None,
    ):
        self.config = config
        self.mapping = mapping
        self.store = store
        self.shares = shares if shares is not None else ShareSet(None, config.storage_root)
        self.printers = list(printers or [])
        self.filer = Filer(config, mapping, self.shares)

    def connect(self) -> IMAPClient:
        client = IMAPClient(self.config.imap_host, port=self.config.imap_port, ssl=self.config.imap_ssl)
        client.login(self.config.imap_user, self.config.imap_password)
        client.select_folder(self.config.imap_folder)
        return client

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

    def _printer_for(self, sender_addr: str) -> Printer | None:
        """The configured device this mail came from, if any (scan-to-mail)."""
        return next((p for p in self.printers if p.matches_sender(sender_addr)), None)

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
                if self.config.imap_oversized_folder:
                    client.move([uid], self.config.imap_oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
            return False

        subject = decode_mime_words(msg.get("Subject"))
        _, sender_addr = parseaddr(decode_mime_words(msg.get("From")))
        body = self._extract_body(msg) if self.config.match_body else ""
        mail_target = self.mapping.resolve(subject, body, account=self.config.account_id)

        # A mail from a known device (scan-to-mail) with a fixed folder goes
        # there regardless of keywords: scanner filenames like "SKM_C250i.pdf"
        # carry no information, and a chance keyword hit would be worse than
        # no match at all.
        printer = self._printer_for(sender_addr)
        forced_target: Target | None = None
        if printer is not None:
            logger.info("UID %s '%s' comes from device '%s'", uid, subject, printer.display_name())
            if printer.has_fixed_target:
                forced_target = Target(
                    folder=printer.target_folder,
                    share=printer.target_share,
                    keyword=f"drucker:{printer.id}",
                )

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

                target, quarantined = self.filer.classify(
                    filename,
                    mail_target,
                    account=self.config.account_id,
                    forced_target=forced_target,
                )
                target_dir = self.filer.directory_for(target, quarantined)
                out_name = self.filer.build_filename(date_prefix, sender_addr, filename)

                if self.config.dry_run:
                    logger.info("[dry-run] would save %s -> %s", out_name, target_dir)
                    continue

                out_path = self.filer.save_bytes(target_dir, out_name, payload)
                logger.info(
                    "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
                    uid,
                    subject,
                    filename,
                    target.keyword or "<fallback>",
                    " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
                    out_path,
                )

        if not self.config.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.config.imap_processed_folder:
                client.move([uid], self.config.imap_processed_folder)
        return True

    @staticmethod
    def _date_prefix(msg: Message) -> str:
        date_header = msg.get("Date")
        if date_header:
            try:
                return parsedate_to_datetime(date_header).strftime("%Y-%m-%d")
            except (TypeError, ValueError):
                pass
        return "unknown-date"

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
