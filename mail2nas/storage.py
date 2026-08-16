"""Where archived attachments end up.

Two backends, same interface:

* `LocalStorage` writes into a directory. Something else (host fstab, a
  bind mount from the Proxmox host) has to have mounted the share there.
* `SmbStorage` speaks SMB directly from this process. Nothing is mounted
  anywhere, so it needs no mount privileges - which is what makes it work
  inside an unprivileged LXC, where the kernel refuses to mount CIFS at all.

The interface deliberately works on *path components* rather than on
strings: the target folders come from `mapping.yaml` on the share and are
untrusted, so they are validated once (`safe_relative_parts`) and then joined
by the backend onto its own root - a local path or a UNC path.
"""
from __future__ import annotations

import errno
import logging
import os
import secrets
from abc import ABC, abstractmethod
from collections.abc import Sequence
from pathlib import Path

from .filenames import safe_relative_parts, unique_path, write_atomic

logger = logging.getLogger(__name__)

TEMP_PREFIX = ".mail2nas-tmp-"


class Storage(ABC):
    """Backend-independent view of the archive target."""

    @property
    @abstractmethod
    def description(self) -> str:
        """Human-readable location, for log lines and error messages."""

    @abstractmethod
    def check_writable(self) -> None:
        """Verify archiving can actually work, or raise SystemExit.

        Called once at startup. Without it, a share that is unreachable or
        read-only is indistinguishable from an empty one, and attachments
        would be written somewhere they silently disappear from.
        """

    @abstractmethod
    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        """Write `data` to `<root>/<parts>/<filename>`, creating directories.

        Never overwrites an existing file (a counter is appended instead) and
        never leaves a partially written file under the final name. Returns
        the full path that was written, for logging.
        """

    @abstractmethod
    def read_text(self, relative: str) -> str:
        """Read a UTF-8 text file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def write_text(self, relative: str, text: str) -> None:
        """Overwrite a UTF-8 text file relative to the root, atomically.

        Unlike `save_unique` this replaces an existing file - it is used for
        the mapping file, which the web UI rewrites in place.
        """

    @abstractmethod
    def list_folders(self, max_depth: int = 2) -> list[str]:
        """Existing directories below the root, as relative POSIX paths.

        Feeds the folder picker in the web UI, so people assign keywords to
        folders that actually exist instead of typing a path by hand. Hidden
        directories are skipped.
        """

    @abstractmethod
    def create_folder(self, relative: str) -> None:
        """Create a directory below the root, including parents."""

    @abstractmethod
    def modified_time(self, relative: str) -> float:
        """Modification time of a file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        """Full path as it would be written, without touching the target."""

    def close(self) -> None:
        """Release connections, if the backend holds any."""


class LocalStorage(Storage):
    """Archive into an already-mounted directory."""

    def __init__(self, root: str):
        self._root = Path(root)

    @property
    def description(self) -> str:
        return str(self._root)

    def check_writable(self) -> None:
        if not self._root.is_dir():
            raise SystemExit(
                f"STORAGE_ROOT {self._root} does not exist or is not a directory - "
                "is the share mounted? (With STORAGE_BACKEND=smb no mount is needed.)"
            )
        if not os.access(self._root, os.W_OK | os.X_OK):
            raise SystemExit(
                f"STORAGE_ROOT {self._root} is not writable by uid {os.getuid()} - "
                "check the mount options (uid/gid/file_mode) and the share permissions."
            )

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        directory = self._root.joinpath(*parts)
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, filename)
        write_atomic(out_path, data)
        return str(out_path)

    def read_text(self, relative: str) -> str:
        return self._resolve(relative).read_text(encoding="utf-8")

    def write_text(self, relative: str, text: str) -> None:
        path = self._resolve(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(path, text.encode("utf-8"))

    def list_folders(self, max_depth: int = 2) -> list[str]:
        found: list[str] = []

        def walk(directory: Path, prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(directory.iterdir(), key=lambda e: e.name.lower())
            except OSError:
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk(entry, f"{relative}/", depth + 1)

        walk(self._root, "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        self._root.joinpath(*safe_relative_parts(relative)).mkdir(parents=True, exist_ok=True)

    def modified_time(self, relative: str) -> float:
        return self._resolve(relative).stat().st_mtime

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        path = self._root.joinpath(*parts)
        return str(path / filename) if filename else str(path)

    def _resolve(self, relative: str) -> Path:
        return self._root.joinpath(*safe_relative_parts(relative))


class SmbStorage(Storage):
    """Archive over SMB, without mounting the share anywhere.

    Every operation goes through `_with_reconnect`: a NAS that reboots, drops
    idle sessions or gets restarted mid-archive is normal in this deployment,
    and the archiver is a long-running process. A failed call therefore gets
    one retry on a fresh session before it is reported.
    """

    def __init__(
        self,
        host: str,
        share: str,
        user: str,
        password: str,
        domain: str | None = None,
        port: int = 445,
        root: str = "",
        encrypt: bool = True,
    ):
        self._host = host
        self._share = share
        self._user = user
        self._password = password
        self._domain = domain or None
        self._port = port
        self._encrypt = encrypt
        self._root_parts = safe_relative_parts(root) if root.strip() else ()
        self._connected = False
        # smbclient keys its connection pool by "server:port" and defaults to
        # 445 on every single call, so a non-default port has to be passed to
        # each operation - not just to register_session, which would otherwise
        # open a second (failing) connection on 445.
        self._kwargs = {"port": self._port}

    @property
    def description(self) -> str:
        # _unc() already prepends the root, so pass no extra components.
        return self._display_unc(())

    # --- session handling ---------------------------------------------------

    def _connect(self) -> None:
        if self._connected:
            return
        import smbclient

        # smbprotocol wants the domain in the username, not as a separate
        # argument. An empty domain must stay absent rather than become
        # "\\user", which some servers reject outright.
        username = f"{self._domain}\\{self._user}" if self._domain else self._user
        smbclient.register_session(
            self._host,
            username=username,
            password=self._password,
            port=self._port,
            encrypt=self._encrypt,
        )
        self._connected = True

    def _reset(self) -> None:
        self._connected = False
        try:
            import smbclient

            # Short timeout: the usual reason for resetting is that the server
            # stopped answering, and the default 60s wait for the logoff reply
            # would stall the retry that is the whole point of resetting.
            smbclient.delete_session(self._host, port=self._port, timeout=5)
        except Exception:  # noqa: BLE001 - tearing down a broken session must not raise
            logger.debug("Could not cleanly close the SMB session to %s", self._host, exc_info=True)

    def _with_reconnect(self, operation: str, func):
        """Run `func`, retrying once on a fresh session if it fails.

        A missing file is a legitimate answer (the mapping file may not exist
        yet), not a broken connection - those propagate without a reconnect,
        so callers can still catch FileNotFoundError.
        """
        self._connect()
        try:
            return func()
        except FileNotFoundError:
            raise
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)
        except Exception as exc:  # noqa: BLE001 - smbprotocol raises non-OSError types too
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)

        self._reset()
        self._connect()
        try:
            return func()
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            raise

    # --- paths ---------------------------------------------------------------

    def _unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        segments = [*self._root_parts, *parts]
        if filename:
            segments.append(filename)
        return "\\".join([f"\\\\{self._host}\\{self._share}", *segments])

    def _display_unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        # Forward slashes in messages, matching how shares are written
        # everywhere else in this project (//nas/Belege/rechnungen).
        return self._unc(parts, filename).replace("\\", "/")

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        return self._display_unc(parts, filename)

    # --- operations ----------------------------------------------------------

    def check_writable(self) -> None:
        """Connect and write a probe file, so a broken setup fails at startup.

        Deliberately a single combined check rather than a reachability test
        followed by a write test: Samba refuses `stat` on a bare share root
        even for users who may write to it, so the write is the only probe
        that answers the question we actually care about.
        """
        probe = f"{TEMP_PREFIX}writetest-{os.getpid()}-{secrets.token_hex(4)}"
        try:
            self._with_reconnect("write test", lambda: self._write_probe(probe))
        except Exception as exc:  # noqa: BLE001 - turn any failure into an actionable message
            where = " (below SMB_ROOT)" if self._root_parts else ""
            raise SystemExit(
                f"Cannot archive to {self.description} over SMB: {exc}\n"
                "Check SMB_HOST/SMB_SHARE/SMB_USER/SMB_PASSWORD (and SMB_DOMAIN if your "
                f"server needs one), and that this user may write to the share{where}. "
                "If the server refuses encryption, set SMB_ENCRYPT=false."
            ) from exc

    def _write_probe(self, name: str) -> None:
        import smbclient

        self._ensure_dir(())
        path = self._unc((), name)
        with smbclient.open_file(path, mode="wb", **self._kwargs) as fh:
            fh.write(b"mail2nas write test")
        smbclient.remove(path, **self._kwargs)

    def _ensure_dir(self, parts: Sequence[str]) -> None:
        import smbclient

        if not parts and not self._root_parts:
            # The share root itself always exists - nothing to create.
            return
        smbclient.makedirs(self._unc(parts), exist_ok=True, **self._kwargs)

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        return self._with_reconnect("write", lambda: self._save_unique(parts, filename, data))

    def _save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        import smbclient
        import smbclient.path

        self._ensure_dir(parts)

        # Pick a free name. Single-writer assumption, same as the local
        # backend: mail2nas is one process per share path.
        target_name = filename
        stem, suffix = Path(filename).stem, Path(filename).suffix
        counter = 0
        while smbclient.path.exists(self._unc(parts, target_name), **self._kwargs):
            counter += 1
            target_name = f"{stem}_{counter}{suffix}"

        # Write to a temporary name and rename into place, so an interrupted
        # transfer can never leave a truncated file under a name that looks
        # like a complete invoice.
        tmp_name = f"{TEMP_PREFIX}{secrets.token_hex(8)}"
        tmp_path = self._unc(parts, tmp_name)
        target_path = self._unc(parts, target_name)
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(data)
            smbclient.replace(tmp_path, target_path, **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

        return self._display_unc(parts, target_name)

    def read_text(self, relative: str) -> str:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("read", lambda: self._read_text(parts))

    def _read_text(self, parts: Sequence[str]) -> str:
        import smbclient

        with smbclient.open_file(
            self._unc(parts[:-1], parts[-1]), mode="r", encoding="utf-8", **self._kwargs
        ) as fh:
            return fh.read()

    def write_text(self, relative: str, text: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("write", lambda: self._write_text(parts, text))

    def _write_text(self, parts: Sequence[str], text: str) -> None:
        import smbclient

        directory, name = tuple(parts[:-1]), parts[-1]
        self._ensure_dir(directory)
        tmp_path = self._unc(directory, f"{TEMP_PREFIX}{secrets.token_hex(8)}")
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(text.encode("utf-8"))
            smbclient.replace(tmp_path, self._unc(directory, name), **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

    def list_folders(self, max_depth: int = 2) -> list[str]:
        return self._with_reconnect("list", lambda: self._list_folders(max_depth))

    def _list_folders(self, max_depth: int) -> list[str]:
        import smbclient

        found: list[str] = []

        def walk(parts: tuple[str, ...], prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(
                    smbclient.scandir(self._unc(parts), **self._kwargs),
                    key=lambda e: e.name.lower(),
                )
            except Exception:  # noqa: BLE001 - an unreadable subfolder must not hide the rest
                logger.debug("Could not list %s", self._unc(parts), exc_info=True)
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk((*parts, entry.name), f"{relative}/", depth + 1)

        walk((), "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("mkdir", lambda: self._ensure_dir(parts))

    def modified_time(self, relative: str) -> float:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("stat", lambda: self._modified_time(parts))

    def _modified_time(self, parts: Sequence[str]) -> float:
        import smbclient

        return smbclient.stat(self._unc(parts[:-1], parts[-1]), **self._kwargs).st_mtime

    def close(self) -> None:
        self._reset()


def from_config(config) -> Storage:
    """Build the storage backend described by the configuration."""
    if config.storage_backend == "smb":
        return SmbStorage(
            host=config.smb_host,
            share=config.smb_share,
            user=config.smb_user,
            password=config.smb_password,
            domain=config.smb_domain,
            port=config.smb_port,
            root=config.smb_root,
            encrypt=config.smb_encrypt,
        )
    return LocalStorage(config.storage_root)
