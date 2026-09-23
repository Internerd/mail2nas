"""The general settings, stored in the database and edited in the web UI.

Everything that used to be a line in the `.env` - folders, limits, the
quarantine list, printing defaults - is an `Options` value now. It is read as
one immutable snapshot, so a worker thread never sees half of a change, and
it is swapped as a whole when the settings page is saved. No restart needed:
the archiver asks for the current snapshot on every message.

Stored as individual keys in the `settings` table rather than as a blob, so
a value added in a later version simply falls back to its default on an
older database instead of making the whole thing unreadable.
"""
from __future__ import annotations

import logging
from collections.abc import Mapping
from dataclasses import dataclass, field, fields, replace

from .config import DEFAULT_BLOCKED_EXTENSIONS, DEFAULT_PRINTABLE_EXTENSIONS, parse_extension_list
from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

SETTING_OPTIONS_SEEDED = "options_seeded"

FILENAME_PREFIXES = {
    "date_sender": "Datum und Absender",
    "date": "nur Datum",
    "sender": "nur Absender",
    "none": "kein Praefix",
}

# (minimum, maximum) for every whole-number setting. Deliberately generous -
# they exist to stop typos ("0", "30000000"), not to second-guess anyone.
LIMITS = {
    "poll_interval": (10, 86_400),
    "max_attachment_size_mb": (1, 2_048),
    "max_message_size_mb": (1, 4_096),
    "max_attachments_per_message": (1, 1_000),
    "pickup_min_age": (0, 86_400),
    "print_timeout": (5, 3_600),
    "retention_days": (30, 3_650),
}

# Keys under which each value is stored. Two predate this module and keep
# their names, so an installation that already edited them keeps its values.
_KEYS = {
    "blocked_extensions": "blocked_extensions",
    "pickup_min_age": "pickup_min_age_seconds",
}


class OptionsError(ValueError):
    """A setting the user tried to save is not usable."""


@dataclass(frozen=True)
class Options:
    """One consistent view of every general setting."""

    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    match_body: bool = False
    filename_prefix: str = "date_sender"
    poll_interval: int = 300
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20
    blocked_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_BLOCKED_EXTENSIONS)
    )
    pickup_min_age: int = 20
    printing_enabled: bool = True
    print_timeout: int = 120
    printable_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_PRINTABLE_EXTENSIONS)
    )
    dry_run: bool = False
    # How long the journal, the log and the list of processed mails are kept.
    retention_days: int = 183


def _key(name: str) -> str:
    return _KEYS.get(name, f"opt.{name}")


def _encode(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, frozenset):
        return ",".join(sorted(value))
    return str(value)


def _decode(name: str, raw: str, default):
    if isinstance(default, bool):
        return raw.strip().lower() in ("1", "true", "yes", "on")
    if isinstance(default, frozenset):
        return parse_extension_list(raw)
    if isinstance(default, int):
        value = int(raw.strip())
        low, high = LIMITS.get(name, (None, None))
        if (low is not None and value < low) or (high is not None and value > high):
            raise ValueError(f"{value} outside {low}..{high}")
        return value
    return raw


class OptionsStore:
    """Reads and writes `Options` in the key/value settings table."""

    def __init__(self, settings):
        self._settings = settings

    def load(self) -> Options:
        defaults = Options()
        values = {}
        for spec in fields(Options):
            raw = self._settings.get(_key(spec.name))
            if raw is None:
                continue
            try:
                values[spec.name] = _decode(spec.name, raw, getattr(defaults, spec.name))
            except (TypeError, ValueError) as exc:
                # Only possible after hand-editing the database. The default
                # is the safer reading than refusing to start.
                logger.warning("Stored setting %s=%r is unusable (%s) - using the default",
                               spec.name, raw, exc)
        return replace(defaults, **values)

    def save(self, options: Options) -> None:
        for spec in fields(Options):
            self._settings.set(_key(spec.name), _encode(getattr(options, spec.name)))

    def seeded(self) -> bool:
        return bool(self._settings.get(SETTING_OPTIONS_SEEDED))

    def seed(self, legacy) -> bool:
        """Carry the general settings of an older `.env` over, once.

        Returns True if anything was taken over. Values already stored (the
        quarantine list and pickup delay were editable before) win over the
        `.env`: they are the newer statement.
        """
        if self.seeded():
            return False
        taken = False
        if legacy is not None and legacy.has_options:
            current = self.load()
            stored = {
                spec.name for spec in fields(Options)
                if self._settings.get(_key(spec.name)) is not None
            }
            carried = {
                name: getattr(legacy, name)
                for name in (
                    "fallback_folder", "quarantine_folder", "match_body", "filename_prefix",
                    "poll_interval", "max_attachment_size_mb", "max_message_size_mb",
                    "max_attachments_per_message", "blocked_extensions", "dry_run",
                    "printing_enabled", "print_timeout", "printable_extensions",
                )
                if name not in stored
            }
            try:
                self.save(validate(_as_form(replace(current, **carried)), current))
                taken = True
            except OptionsError as exc:
                logger.error("Settings from the .env are not usable (%s) - keeping defaults", exc)
        self._settings.set(SETTING_OPTIONS_SEEDED, "1")
        return taken


def _as_form(options: Options) -> dict[str, str]:
    """An Options value as the settings form would submit it."""
    form = {}
    for spec in fields(Options):
        value = getattr(options, spec.name)
        if isinstance(value, bool):
            if value:
                form[spec.name] = "1"
        elif isinstance(value, frozenset):
            form[spec.name] = ", ".join(sorted(value))
        else:
            form[spec.name] = str(value)
    return form


def as_form(options: Options) -> dict[str, str]:
    return _as_form(options)


def _folder(form: Mapping[str, str], name: str, label: str) -> str:
    value = (form.get(name) or "").strip().replace("\\", "/")
    if not value:
        raise OptionsError(f"Bitte einen {label} angeben.")
    try:
        return "/".join(safe_relative_parts(value))
    except ValueError as exc:
        raise OptionsError(f"{label}: {exc}") from None


def _whole(form: Mapping[str, str], name: str, label: str) -> int:
    raw = (form.get(name) or "").strip()
    try:
        value = int(raw)
    except ValueError:
        raise OptionsError(f"{label} muss eine ganze Zahl sein.") from None
    low, high = LIMITS[name]
    if not low <= value <= high:
        raise OptionsError(f"{label} muss zwischen {low} und {high} liegen.")
    return value


def _whole_or(form: Mapping[str, str], name: str, label: str, current: int) -> int:
    """Like `_whole`, but a field the form did not send keeps its value -
    for settings added later, so an older form (or script) still saves."""
    if name not in form:
        return current
    return _whole(form, name, label)


def validate(form: Mapping[str, str], current: Options | None = None) -> Options:
    """Turn the submitted settings form into Options, or explain what is wrong.

    Checkboxes are absent when unticked, so a missing flag means False. The
    extension lists may be empty on purpose - the UI says what that means.
    """
    current = current or Options()
    prefix = (form.get("filename_prefix") or current.filename_prefix).strip()
    if prefix not in FILENAME_PREFIXES:
        raise OptionsError("Unbekanntes Dateinamen-Praefix.")

    fallback = _folder(form, "fallback_folder", "Ordner fuer Anhaenge ohne Treffer")
    quarantine = _folder(form, "quarantine_folder", "Quarantaene-Ordner")
    if fallback == quarantine:
        raise OptionsError(
            "Fallback- und Quarantaene-Ordner muessen verschieden sein - sonst liegen "
            "gesperrte Dateien zwischen den normalen."
        )

    return Options(
        fallback_folder=fallback,
        quarantine_folder=quarantine,
        match_body=bool(form.get("match_body")),
        filename_prefix=prefix,
        poll_interval=_whole(form, "poll_interval", "Das Abrufintervall"),
        max_attachment_size_mb=_whole(form, "max_attachment_size_mb", "Die Groesse je Anhang"),
        max_message_size_mb=_whole(form, "max_message_size_mb", "Die Groesse je Mail"),
        max_attachments_per_message=_whole(
            form, "max_attachments_per_message", "Die Zahl der Anhaenge je Mail"
        ),
        blocked_extensions=parse_extension_list(form.get("blocked_extensions", "")),
        pickup_min_age=_whole(form, "pickup_min_age", "Die Wartezeit fuer Abholordner"),
        printing_enabled=bool(form.get("printing_enabled")),
        print_timeout=_whole(form, "print_timeout", "Die Zeitgrenze fuer Druckauftraege"),
        printable_extensions=parse_extension_list(form.get("printable_extensions", "")),
        dry_run=bool(form.get("dry_run")),
        retention_days=_whole_or(
            form, "retention_days", "Die Aufbewahrungsdauer", current.retention_days
        ),
    )
