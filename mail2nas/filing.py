from __future__ import annotations

import logging
from email.header import decode_header, make_header
from pathlib import Path

from .config import Config
from .filenames import copy_atomic, sanitize_filename, unique_path, write_atomic
from .mapping import Mapping, Target
from .shares import ShareSet

logger = logging.getLogger(__name__)


def decode_mime_words(value: str | None) -> str:
    """Decode RFC 2047 encoded words ("=?utf-8?B?...?=") to plain text."""
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def extension_of(filename: str) -> str:
    if "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].strip().lower()


class Filer:
    """Decides where a document goes and puts it there.

    Shared by the mail archiver and the printer pickup so both apply exactly
    the same rules, quarantine and naming - a scan that arrives by mail and
    the same scan dropped into a NAS folder must not end up in different
    places.
    """

    def __init__(self, config: Config, mapping: Mapping, shares: ShareSet):
        self.config = config
        self.mapping = mapping
        self.shares = shares

    # --- where does it go -------------------------------------------------

    def classify(
        self,
        filename: str,
        fallback_target: Target,
        account: str | None = None,
        forced_target: Target | None = None,
    ) -> tuple[Target, bool]:
        """Return (target, quarantined) for a single document.

        The document's own filename is checked against the mapping first, so
        several differently-named attachments of one mail can land in
        different folders. `fallback_target` is used when the filename itself
        gives no hint (for mail: the subject/body match). `forced_target`
        short-circuits both - that is a device with a fixed folder, which
        knows better than a keyword found in a scanner's filename.

        A blocked extension always wins: an executable can never be renamed
        into a trusted-looking business folder just by calling it
        "Rechnung.exe".
        """
        readable = decode_mime_words(filename)
        if forced_target is not None:
            target = forced_target
        else:
            target = self.mapping.resolve(readable, account=account)
            if target.keyword is None:
                target = fallback_target

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(readable), extension_of(sanitize_filename(readable))}
        if extensions & self.config.blocked_extensions:
            return (
                Target(
                    folder=self.config.quarantine_folder,
                    share=target.share,
                    keyword=target.keyword,
                ),
                True,
            )
        return target, False

    def directory_for(self, target: Target, quarantined: bool = False) -> Path:
        """Map a Target onto a directory on a mounted share.

        Folder names come from mapping.yaml on the share and are therefore
        untrusted; anything that would escape the share root is rejected and
        replaced with the fallback folder rather than being written outside.
        A share whose mount point is gone is skipped as well, so a NAS that is
        down diverts documents to the default share instead of quietly filling
        up the local disk behind the mount point.

        A quarantined document falls back to a quarantine folder only: a
        misconfigured quarantine path must never drop an executable into the
        folder people open invoices from.
        """
        if quarantined:
            candidates = [
                (target.share, target.folder, None),
                ("", self.config.quarantine_folder, "built-in quarantine"),
                ("", "quarantaene", "built-in quarantine"),
            ]
        else:
            candidates = [
                (target.share, target.folder, None),
                ("", self.config.fallback_folder, "fallback"),
                ("", "unsorted", "built-in"),
            ]
        for share_id, folder, note in candidates:
            try:
                directory = self.shares.resolve(share_id, folder)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the share root", folder, exc
                )
                continue
            problem = self.shares.problem_with(share_id)
            if problem:
                logger.error("Share %r is not usable (%s)", self.shares.label_for(share_id), problem)
                continue
            if note:
                logger.warning("Using %s folder %r instead of %r", note, folder, target.folder)
            return directory
        raise ValueError("No usable target folder on any mounted share")

    # --- how is it named --------------------------------------------------

    def build_filename(self, date_prefix: str, sender: str, filename: str) -> str:
        filename = sanitize_filename(decode_mime_words(filename))
        mode = self.config.filename_prefix
        if mode == "none":
            return filename
        if mode == "date":
            return f"{date_prefix}_{filename}"
        sender = sanitize_filename(sender or "unknown")
        if mode == "sender":
            return f"{sender}_{filename}"
        return f"{date_prefix}_{sender}_{filename}"

    # --- writing ----------------------------------------------------------

    def save_bytes(self, directory: Path, name: str, payload: bytes) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, name)
        write_atomic(out_path, payload)
        return out_path

    def move_file(self, source: Path, directory: Path, name: str) -> Path:
        """Copy `source` into `directory` and remove it afterwards.

        Copy-then-delete rather than a rename: source and target can be on
        different shares, and the original must only disappear once the copy
        is complete and flushed.
        """
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, name)
        copy_atomic(source, out_path)
        try:
            source.unlink()
        except OSError:
            # The copy is only legitimate if the original goes away: a pickup
            # folder we cannot delete from would otherwise hand us the same
            # document again on every cycle.
            out_path.unlink(missing_ok=True)
            raise
        return out_path
