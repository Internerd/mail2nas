from __future__ import annotations

import os
import re
from dataclasses import dataclass


# Executable/script types that are quarantined instead of filed normally,
# even if their filename happens to match a mapping keyword. This is a
# defense-in-depth measure against mail attachments being used to smuggle
# malware onto the archive share - it does not make opening the quarantined
# file safe, it just keeps it out of the regular business-document folders.
DEFAULT_BLOCKED_EXTENSIONS = (
    "exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,"
    "jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk"
)

# Formats CUPS prints without help. Office documents are deliberately absent:
# without a converter installed they come out as pages of raw markup, and
# installing one is a decision for whoever runs the container.
DEFAULT_PRINTABLE_EXTENSIONS = "pdf,ps,txt,text,log,csv,png,jpg,jpeg,gif,bmp,tif,tiff"


def _bool(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


def parse_extension_list(raw: str) -> frozenset[str]:
    """Normalise a list of file extensions ('.EXE, com; bat' -> {exe, com, bat}).

    Accepts commas, semicolons and whitespace as separators, because the
    field is typed by hand in the web UI and every one of those gets used.
    """
    return frozenset(
        ext.strip().lower().lstrip(".")
        for ext in re.split(r"[,;\s]+", raw or "")
        if ext.strip()
    )




def _int(name: str, default: str, minimum: int = 1, maximum: int | None = None) -> int:
    """Read an integer setting, failing with a usable message instead of a traceback."""
    raw = os.environ.get(name, default).strip()
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"{name} must be a whole number, got {raw!r}") from None
    if value < minimum or (maximum is not None and value > maximum):
        allowed = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise SystemExit(f"{name} must be {allowed}, got {value}")
    return value








def _lpstat_binary() -> str:
    """Where `lpstat` is, defaulting to `lp`'s directory."""
    explicit = os.environ.get("LPSTAT_BINARY", "").strip()
    if explicit:
        return explicit
    lp = os.environ.get("LP_BINARY", "lp").strip() or "lp"
    return lp[:-2] + "lpstat" if lp.endswith("lp") else "lpstat"


@dataclass(frozen=True)
class Config:
    """What the container itself needs before anything else can run.

    Everything about *what* mail2nas does - mailboxes, archives, rules,
    printers, limits - lives in the local database and is edited in the web
    UI. What is left here is infrastructure: where the database is, which port
    the UI listens on, which binaries to call. None of it is secret and none of
    it is required, so a container starts with an empty `.env` and the rest is
    set up in the browser.

    Older `.env` files still work: their values are read once by `legacy.py`
    and carried into the database on the first start of this version.
    """

    state_db_path: str = "/data/state.db"
    web_host: str = "0.0.0.0"
    web_port: int = 8080
    # Initial password only, and optional: without one, a random password is
    # generated on first start. The stored hash wins as soon as there is one.
    web_password: str = ""
    web_cookie_secure: bool = False
    lp_binary: str = "lp"
    # `lpstat` is only used to list a CUPS server's queues for the printer
    # search; it sits next to `lp`, so it is derived from it unless overridden.
    lpstat_binary: str = "lpstat"

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            state_db_path=os.environ.get("STATE_DB_PATH", "/data/state.db").strip() or "/data/state.db",
            web_host=os.environ.get("WEB_HOST", "0.0.0.0").strip() or "0.0.0.0",
            web_port=_int("WEB_PORT", "8080", minimum=1, maximum=65535),
            web_password=os.environ.get("WEB_PASSWORD", ""),
            web_cookie_secure=_bool("WEB_COOKIE_SECURE", False),
            lp_binary=os.environ.get("LP_BINARY", "lp").strip() or "lp",
            lpstat_binary=_lpstat_binary(),
        )

    @property
    def data_dir(self) -> str:
        """The directory next to the database - for files the UI hands out."""
        return os.path.dirname(os.path.abspath(self.state_db_path))
