"""Finding printers that are already on the network.

Two sources, because there are two kinds of "printer" in this context:

* **Queues on a CUPS server** (`lpstat -v`). These are ready to use: their
  name is exactly what goes into a printer's "Warteschlange", and printing
  works the moment it is saved.
* **Devices advertising themselves via mDNS/DNS-SD** (`_ipp._tcp` and
  friends), which is how AirPrint/driverless printers announce their
  presence. These are found even when nothing has been set up yet - but a
  raw device is not a CUPS queue, so the UI says how to turn it into one.

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
    destination: str  # queue name / IPP resource
    server: str  # "host" or "host:port"; empty = the local CUPS server
    source: str  # "cups" or "mdns"
    detail: str = ""  # device URI or model, shown to the user

    @property
    def ready_to_use(self) -> bool:
        """True if this can be printed on as-is (a real CUPS queue)."""
        return self.source == "cups"

    def lpadmin_command(self) -> str:
        """How to turn a discovered device into a CUPS queue, for copy & paste."""
        uri = self.detail or f"ipp://{self.server}/{self.destination}"
        queue = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in self.name) or "drucker"
        return f"lpadmin -p {queue} -v {uri} -E -m everywhere"


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
        server = address if port in (631, 0) else f"{address}:{port}"
        found.append(
            Found(
                name=label or instance,
                destination=queue,
                server=server,
                source="mdns",
                detail=f"ipp://{address}:{port}/{queue}",
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


# --- both -------------------------------------------------------------------


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

    try:
        found.extend(cups_queues(server, lpstat_binary=lpstat_binary, timeout=timeout))
    except DiscoveryError as exc:
        problems.append(f"CUPS ({server or 'lokal'}): {exc}")

    if include_mdns:
        known = {(entry.detail or "").lower() for entry in found}
        for entry in mdns_printers(timeout=mdns_timeout):
            if entry.detail.lower() in known:
                continue
            found.append(entry)
        if not any(entry.source == "mdns" for entry in found):
            problems.append(
                "Per mDNS wurde nichts gefunden. In einem Docker-Netz ist Multicast "
                "normalerweise nicht erreichbar - dann hilft nur der CUPS-Server oben "
                "oder das Geraet von Hand einzutragen."
            )

    return found, problems
