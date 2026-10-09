"""Finding printers that are already on the network.

Three sources, because there are two kinds of "printer" in this context:

* **Queues on a CUPS server** (`lpstat -v`). Their name is exactly what goes
  into a printer's "Warteschlange".
* **A device asked directly** over IPP, when an address is typed into the
  search field: a printer that speaks IPP (AirPrint, Mopria, IPP Everywhere -
  nearly every network printer) answers with its model and formats, and can
  be printed on directly as `ipp://<address>/...` (see `ipp.py`).
* **Devices advertising themselves via mDNS/DNS-SD** (`_ipp._tcp` and
  friends). Usable directly the same way.

Everything here is best-effort and bounded: discovery runs inside a web
request, and an unreachable CUPS server or a network that swallows multicast
must return an empty list quickly rather than hang the page.
"""
from __future__ import annotations

import logging
import socket
import struct
import subprocess
import time
from dataclasses import dataclass

logger = logging.getLogger(__name__)

MDNS_ADDRESS = "224.0.0.251"
MDNS_PORT = 5353
# The services a network printer announces itself under. _pdl-datastream is
# raw port-9100 printing, which many devices offer alongside IPP.
MDNS_SERVICES = ("_ipp._tcp.local", "_ipps._tcp.local", "_pdl-datastream._tcp.local")
MAX_RESPONSE_BYTES = 9000
MAX_NAME_JUMPS = 20

TYPE_A = 1
TYPE_PTR = 12
TYPE_TXT = 16
TYPE_SRV = 33
# Unicast-response bit (RFC 6762 5.4): without it responders answer by
# multicast to port 5353, which a one-shot client is not listening on.
QCLASS_IN_UNICAST = 0x8001


@dataclass(frozen=True)
class Found:
    """One discovered printer, in the terms the printer form needs."""

    name: str
    destination: str  # CUPS queue name, or the device address ipp://...
    server: str  # CUPS server "host" or "host:port"; empty = local / direct
    source: str  # "cups", "ipp" (asked directly) or "mdns"
    detail: str = ""  # device URI or model, shown to the user

    @property
    def direct(self) -> bool:
        """Printed on directly over IPP, without a CUPS server."""
        return self.source in ("ipp", "mdns")


# --- CUPS ------------------------------------------------------------------


def cups_queues(server: str = "", lpstat_binary: str = "lpstat", timeout: int = 10) -> list[Found]:
    """Ask a CUPS server which queues it has.

    `lpstat -v` is used rather than `-e`: it names the device behind each
    queue, which is what tells two similarly named queues apart.
    """
    command = [lpstat_binary]
    if server.strip():
        command += ["-h", server.strip()]
    command += ["-v"]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError:
        raise DiscoveryError(
            f"{lpstat_binary} nicht gefunden - im Container fehlt das Paket cups-client."
        ) from None
    except subprocess.TimeoutExpired:
        raise DiscoveryError(
            f"Der CUPS-Server hat nicht innerhalb von {timeout}s geantwortet."
        ) from None
    except OSError as exc:
        raise DiscoveryError(f"CUPS-Abfrage fehlgeschlagen: {exc}") from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip()
        raise DiscoveryError(message or f"{lpstat_binary} endete mit Code {result.returncode}")

    return parse_lpstat(result.stdout or "", server.strip())


def parse_lpstat(output: str, server: str = "") -> list[Found]:
    """Turn `lpstat -v` output into printers.

    Lines look like::

        device for Buero_MFP: ipp://192.168.1.50:631/ipp/print
        Gerät für Flur: socket://192.168.1.51:9100

    The prefix is localised, so the colon is what is parsed, not the words.
    """
    found: list[Found] = []
    for line in output.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        head, _, uri = line.partition(":")
        # "device for NAME" / "Gerät für NAME" - the queue is the last word.
        queue = head.split()[-1] if head.split() else ""
        uri = uri.strip()
        if not queue or not uri:
            continue
        found.append(
            Found(name=queue, destination=queue, server=server, source="cups", detail=uri)
        )
    return found


class DiscoveryError(RuntimeError):
    """Discovery could not be carried out (as opposed to finding nothing)."""


# --- mDNS / DNS-SD ----------------------------------------------------------


def _encode_name(name: str) -> bytes:
    parts = [label.encode("utf-8") for label in name.strip(".").split(".")]
    return b"".join(bytes([len(p)]) + p for p in parts) + b"\x00"


def _query(service: str) -> bytes:
    header = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + _encode_name(service) + struct.pack(">HH", TYPE_PTR, QCLASS_IN_UNICAST)


def _read_name(data: bytes, offset: int) -> tuple[str, int]:
    """Decode a (possibly compressed) DNS name. Returns (name, offset after it)."""
    labels: list[str] = []
    jumps = 0
    after: int | None = None
    while True:
        if offset >= len(data):
            raise ValueError("truncated name")
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length & 0xC0 == 0xC0:  # compression pointer
            if offset + 1 >= len(data):
                raise ValueError("truncated pointer")
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if after is None:
                after = offset + 2
            jumps += 1
            if jumps > MAX_NAME_JUMPS or pointer >= len(data):
                raise ValueError("name pointer loop")
            offset = pointer
            continue
        start = offset + 1
        offset = start + length
        if offset > len(data):
            raise ValueError("truncated label")
        labels.append(data[start:offset].decode("utf-8", "replace"))
    return ".".join(labels), (after if after is not None else offset)


def _read_records(data: bytes) -> list[tuple[str, int, bytes, int]]:
    """Every resource record as (name, type, rdata, rdata offset)."""
    if len(data) < 12:
        return []
    _, _, questions, answers, authority, additional = struct.unpack(">HHHHHH", data[:12])
    offset = 12
    for _ in range(questions):
        _, offset = _read_name(data, offset)
        offset += 4
    records = []
    for _ in range(answers + authority + additional):
        name, offset = _read_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _rclass, _ttl, rdlength = struct.unpack(">HHIH", data[offset : offset + 10])
        offset += 10
        rdata = data[offset : offset + rdlength]
        records.append((name, rtype, rdata, offset))
        offset += rdlength
    return records


def _parse_txt(rdata: bytes) -> dict[str, str]:
    values: dict[str, str] = {}
    index = 0
    while index < len(rdata):
        length = rdata[index]
        index += 1
        chunk = rdata[index : index + length].decode("utf-8", "replace")
        index += length
        key, _, value = chunk.partition("=")
        if key:
            values[key.lower()] = value
    return values


def parse_responses(packets: list[bytes]) -> list[Found]:
    """Build the printer list from raw mDNS response packets.

    Split out from the socket handling so the parsing - the part with the
    interesting edge cases - can be tested without a network.
    """
    services: dict[str, dict] = {}
    hosts: dict[str, str] = {}

    for data in packets:
        try:
            records = _read_records(data)
        except (ValueError, struct.error):
            logger.debug("Ignoring an unparsable mDNS packet", exc_info=True)
            continue
        for name, rtype, rdata, rdata_offset in records:
            try:
                if rtype == TYPE_SRV and len(rdata) >= 7:
                    _, _, port = struct.unpack(">HHH", rdata[:6])
                    target, _ = _read_name(data, rdata_offset + 6)
                    entry = services.setdefault(name, {})
                    entry["host"] = target.rstrip(".")
                    entry["port"] = port
                elif rtype == TYPE_TXT:
                    services.setdefault(name, {})["txt"] = _parse_txt(rdata)
                elif rtype == TYPE_A and len(rdata) == 4:
                    hosts[name.rstrip(".")] = socket.inet_ntoa(rdata)
            except (ValueError, struct.error):
                logger.debug("Ignoring an unparsable mDNS record", exc_info=True)

    found: list[Found] = []
    for service_name, entry in services.items():
        host = entry.get("host")
        if not host:
            continue
        txt = entry.get("txt", {})
        port = entry.get("port", 631)
        address = hosts.get(host, host)
        instance = service_name.split("._")[0].replace("\\032", " ")
        label = txt.get("ty") or txt.get("product", "").strip("()") or instance
        queue = (txt.get("rp") or "ipp/print").lstrip("/")
        scheme = "ipps" if "._ipps." in service_name else "ipp"
        where = address if port in (631, 0) else f"{address}:{port}"
        found.append(
            Found(
                name=label or instance,
                destination=f"{scheme}://{where}/{queue}",
                server="",
                source="mdns",
                detail=txt.get("ty") or "",
            )
        )
    return found


def mdns_printers(timeout: float = 3.0) -> list[Found]:
    """One-shot DNS-SD query for the usual printer services.

    Returns an empty list rather than raising when multicast is unavailable:
    inside a bridged container that is the normal case, not an error worth
    failing the page over.
    """
    packets: list[bytes] = []
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    except OSError as exc:
        logger.info("No mDNS discovery: %s", exc)
        return []
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        sock.bind(("", 0))
        for service in MDNS_SERVICES:
            try:
                sock.sendto(_query(service), (MDNS_ADDRESS, MDNS_PORT))
            except OSError as exc:
                logger.info("Could not send the mDNS query for %s: %s", service, exc)

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, _sender = sock.recvfrom(MAX_RESPONSE_BYTES)
            except (TimeoutError, socket.timeout):
                break
            except OSError as exc:
                logger.info("mDNS discovery stopped: %s", exc)
                break
            packets.append(data)
    finally:
        sock.close()
    return parse_responses(packets)


# --- a device, asked directly -------------------------------------------------

# Where printers listen for IPP. ipp/print is what IPP Everywhere, AirPrint and
# Mopria prescribe; the others are what older Brother, HP and Epson firmware use.
IPP_PATHS = ("ipp/print", "ipp/port1", "ipp", "ipp/printer", "printer")


def ipp_device(address: str, timeout: float = 4.0) -> Found | None:
    """Ask `address` (host, host:port or a full ipp:// URI) whether it is an
    IPP printer. Returns it ready to use, or None."""
    from . import ipp

    address = address.strip().rstrip("/")
    if address.lower().startswith(("ipp://", "ipps://")):
        candidates = [address]
    else:
        host = address.split("://", 1)[-1]
        host, slash, path = host.partition("/")
        candidates = [f"ipp://{host}/{p}" for p in IPP_PATHS]
        if slash and path:
            # "10.0.0.5/ipp/port1" - the path was given, try it first.
            candidates.insert(0, f"ipp://{host}/{path}")

    for uri in candidates:
        try:
            response = ipp.printer_attributes(uri, timeout=timeout)
        except ipp.IppError as exc:
            if "nicht erreichbar" in str(exc):
                # Nobody listening on the IPP port at all - other paths on
                # the same port will not answer either.
                logger.info("No IPP printer at %s: %s", address, exc)
                return None
            continue
        model = response.first("printer-make-and-model") or response.first("printer-info") or ""
        formats = [f for f in response.attributes.get("document-format-supported", []) if f]
        usable = [f for f in formats if f in ("application/pdf", "image/pwg-raster", "image/urf")]
        return Found(
            name=str(model or response.first("printer-name") or address),
            destination=uri,
            server="",
            source="ipp",
            detail="Formate: " + (", ".join(usable) or ", ".join(formats[:6]) or "unbekannt"),
        )
    return None


# --- all of it ----------------------------------------------------------------


def _same_device(uri: str) -> str:
    """Comparable form of a device URI: ipps -> ipp, default port dropped."""
    uri = (uri or "").strip().lower().rstrip("/")
    if uri.startswith("ipps://"):
        uri = "ipp://" + uri[len("ipps://"):]
    return uri.replace(":631/", "/")



def discover(
    server: str = "",
    lpstat_binary: str = "lpstat",
    timeout: int = 10,
    mdns_timeout: float = 3.0,
    include_mdns: bool = True,
) -> tuple[list[Found], list[str]]:
    """Everything that could be found, plus the problems worth telling about.

    The queues of a CUPS server come first - they are the ones that can be
    used straight away - followed by devices that only announced themselves.
    A device already backing a queue is dropped from the second list.
    """
    found: list[Found] = []
    problems: list[str] = []
    server = server.strip()

    cups_problem = None
    if not server.lower().startswith(("ipp://", "ipps://")):
        try:
            found.extend(cups_queues(server, lpstat_binary=lpstat_binary, timeout=timeout))
        except DiscoveryError as exc:
            cups_problem = f"CUPS ({server or 'lokal'}): {exc}"

    if server and not found:
        # Very often what was typed in is the printer itself, not a CUPS
        # server - which then answers "operation not supported" to lpstat.
        device = ipp_device(server)
        if device is not None:
            found.append(device)
            cups_problem = None
        elif cups_problem is None:
            cups_problem = f"{server}: weder CUPS-Server noch IPP-Drucker gefunden."
        else:
            cups_problem += " - und auch kein IPP-Drucker unter dieser Adresse."
    if cups_problem and (server or not found):
        problems.append(cups_problem)

    if include_mdns:
        known = {_same_device(entry.destination) for entry in found} | {
            _same_device(entry.detail) for entry in found
        }
        for entry in mdns_printers(timeout=mdns_timeout):
            if _same_device(entry.destination) in known:
                continue
            found.append(entry)
        if not any(entry.source == "mdns" for entry in found):
            problems.append(
                "Per mDNS wurde nichts gefunden. In einem Docker-Netz ist Multicast "
                "normalerweise nicht erreichbar - dann oben die IP-Adresse des Druckers "
                "eingeben."
            )

    return found, problems
