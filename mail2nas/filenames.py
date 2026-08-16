from __future__ import annotations

import os
import re
import tempfile
import unicodedata
from pathlib import Path

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")

# Characters that are path separators, reserved on Windows/SMB, or control
# characters. Folder names keep spaces and non-ASCII letters (people do name
# folders "Rechnungen 2026"), so this is deliberately more permissive than
# the attachment-filename sanitizer.
_UNSAFE_SEGMENT = re.compile(r'[\x00-\x1f\x7f<>:"|?*\\/]+')


def sanitize_filename(name: str) -> str:
    """Strip characters that are awkward on SMB shares / cross-platform filesystems."""
    name = unicodedata.normalize("NFKD", name)
    name = _UNSAFE.sub("_", name).strip("._")
    return name or "attachment"


def sanitize_path_segment(segment: str) -> str:
    """Sanitize a single folder-name component (never a path)."""
    segment = unicodedata.normalize("NFKC", segment)
    segment = _UNSAFE_SEGMENT.sub("_", segment)
    # Trailing dots/spaces are silently dropped by Windows/SMB, which would
    # make the on-disk name differ from what was configured.
    return segment.strip().rstrip(". ").strip()


def safe_relative_parts(relative: str) -> tuple[str, ...]:
    """Split `relative` into validated, sanitized path components.

    The target folders come from `mapping.yaml`, which lives on the archive
    share itself - so whoever can edit that file could otherwise redirect
    attachments anywhere the process can write, via `../..` or an absolute
    path.

    Absolute paths and `..` components are refused rather than reinterpreted,
    and every remaining component is sanitized. Nested targets such as
    "rechnungen/2026" stay supported. Raises ValueError if nothing usable is
    left, so the caller can fall back to a known-good folder.

    Returning components rather than a joined path keeps this usable for both
    storage backends: the local one joins them onto a filesystem root, the SMB
    one onto a UNC path.
    """
    raw = str(relative).replace("\\", "/")

    if raw.strip().startswith("/"):
        # Confining "/etc/cron.d" to "<root>/etc/cron.d" would be safe but
        # produces a surprising deep tree on the share. An absolute target is
        # always a misconfiguration, so say so and let the caller fall back.
        raise ValueError(f"Target folder must be relative to the storage root: {relative!r}")

    parts: list[str] = []
    for candidate in raw.split("/"):
        candidate = candidate.strip()
        if candidate in ("", "."):
            continue
        if candidate == "..":
            raise ValueError(f"Refusing parent-directory component in target folder: {relative!r}")
        cleaned = sanitize_path_segment(candidate)
        if not cleaned or cleaned == "..":
            raise ValueError(f"Target folder component is empty after sanitizing: {relative!r}")
        parts.append(cleaned)

    if not parts:
        raise ValueError(f"Target folder is empty: {relative!r}")

    return tuple(parts)


def safe_join(root: str | Path, relative: str) -> Path:
    """Join `relative` onto `root`, guaranteeing the result stays under `root`.

    See `safe_relative_parts` for what is accepted. (Note `Path("/mnt/nas") /
    "/etc"` yields `/etc`: an absolute right operand discards the root
    entirely - hence the validation rather than a plain join.)
    """
    root_path = Path(root)
    result = root_path.joinpath(*safe_relative_parts(relative))

    # Belt and braces: the component filtering above already makes escaping
    # impossible, but verify containment lexically so any future change to the
    # parsing cannot silently reopen the hole.
    root_abs = os.path.abspath(root_path)
    result_abs = os.path.abspath(result)
    if result_abs != root_abs and not result_abs.startswith(root_abs.rstrip(os.sep) + os.sep):
        raise ValueError(f"Target folder escapes the storage root: {relative!r}")

    return result


def unique_path(directory: str | Path, filename: str) -> Path:
    """Return a path for `filename` inside `directory`, avoiding overwrites."""
    directory = Path(directory)
    candidate = directory / filename
    if not candidate.exists():
        return candidate

    stem, suffix = Path(filename).stem, Path(filename).suffix
    counter = 1
    while True:
        candidate = directory / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def write_atomic(path: str | Path, data: bytes) -> None:
    """Write `data` to `path` via a temporary file plus rename.

    A direct write that is interrupted (container restart, SMB share dropping
    mid-transfer) would leave a truncated file behind that still looks like a
    complete invoice. Renaming into place means the final name only ever
    appears once the bytes are fully written.
    """
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mail2nas-tmp-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
