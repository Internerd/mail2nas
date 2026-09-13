from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_join
from .settings import DEFAULT_SHARE, Share

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ShareStatus:
    id: str
    label: str
    path: str
    enabled: bool
    ok: bool
    problem: str | None


class ShareSet:
    """The configured archive destinations, resolved to directories on disk.

    One mail2nas instance can file onto several shares (typically several NAS
    boxes mounted at different paths). Rules, printers and folders address a
    share by id; the empty id means "the default share", so a mapping file
    written before multi-share support keeps working unchanged.

    Nothing here mounts anything: a share is a directory that the operating
    system has already mounted. That is also why every write re-checks the
    mount point - if a NAS goes away, its mount point usually stays behind as
    an empty local directory, and writing into it would put invoices into the
    container's own filesystem where nobody looks for them.
    """

    def __init__(self, shares: list[Share] | None, fallback_root: str | Path):
        self._shares = [s for s in (shares or []) if s.path]
        self._fallback_root = str(fallback_root)

    @classmethod
    def from_settings(cls, settings, fallback_root: str | Path) -> "ShareSet":
        return cls(settings.shares, fallback_root)

    # --- lookups --------------------------------------------------------

    @property
    def shares(self) -> list[Share]:
        return list(self._shares)

    def _enabled(self) -> list[Share]:
        return [s for s in self._shares if s.enabled]

    def default(self) -> Share | None:
        return next(iter(self._enabled()), None) or next(iter(self._shares), None)

    def get(self, share_id: str) -> Share | None:
        """The share with this id, or the default share for '' / unknown ids."""
        if share_id and share_id != DEFAULT_SHARE:
            share = next((s for s in self._shares if s.id == share_id), None)
            if share is not None and share.enabled:
                return share
            if share is not None:
                logger.warning("Share %r is disabled - using the default share instead", share_id)
            else:
                logger.warning("Unknown share %r - using the default share instead", share_id)
        return self.default()

    def root_for(self, share_id: str) -> Path:
        share = self.get(share_id)
        return Path(share.path if share is not None else self._fallback_root)

    def label_for(self, share_id: str) -> str:
        share = self.get(share_id)
        return share.display_name() if share is not None else "NAS"

    def resolve(self, share_id: str, folder: str) -> Path:
        """Directory for `folder` on `share_id`. Raises ValueError if unsafe."""
        return safe_join(self.root_for(share_id), folder)

    # --- mount checks ---------------------------------------------------

    @staticmethod
    def check_root(root: str | Path) -> str | None:
        """Return a problem description for this mount point, or None if it is fine."""
        path = Path(root)
        if not str(path).strip():
            return "kein Pfad hinterlegt"
        if not path.exists():
            return f"{path} existiert nicht - ist das Share gemountet?"
        if not path.is_dir():
            return f"{path} ist kein Verzeichnis"
        if not os.access(path, os.W_OK | os.X_OK):
            return f"{path} ist fuer uid {os.getuid()} nicht beschreibbar"
        return None

    def problem_with(self, share_id: str) -> str | None:
        share = self.get(share_id)
        if share is None:
            return self.check_root(self._fallback_root)
        return self.check_root(share.path)

    def status(self) -> list[ShareStatus]:
        default = self.default()
        if not self._shares:
            # Nothing configured yet: STORAGE_ROOT is the archive target.
            return [
                ShareStatus(
                    id=DEFAULT_SHARE,
                    label="Standard-Ablage (STORAGE_ROOT)",
                    path=self._fallback_root,
                    enabled=True,
                    ok=self.check_root(self._fallback_root) is None,
                    problem=self.check_root(self._fallback_root),
                )
            ]
        result = []
        for share in self._shares:
            problem = self.check_root(share.path) if share.enabled else None
            result.append(
                ShareStatus(
                    id=share.id,
                    label=share.display_name() + (" (Standard)" if share is default else ""),
                    path=share.path,
                    enabled=share.enabled,
                    ok=problem is None,
                    problem=problem,
                )
            )
        return result
