"""Printing straight to a network printer over IPP - no CUPS server needed.

Almost every network printer sold in the last ten years speaks IPP: it is
what AirPrint and Mopria are built on. Such a printer can be addressed as
`ipp://<address>/ipp/print` and accepts a job directly - which means a
household with one Brother on the shelf does not need a CUPS server just so
mail2nas can print an invoice.

The catch is the document format. Many small printers do not understand PDF
at all; what they are guaranteed to accept is a raster format (PWG raster for
IPP Everywhere/Mopria, URF for AirPrint). So a document is turned into PDF
first (`render.py`) and then, if the printer cannot take PDF, rasterised with
Ghostscript in the format and resolution the printer says it supports.

The protocol part is small and implemented here directly (RFC 8010/8011):
one request to ask the printer what it can do, one to send the job.
"""
from __future__ import annotations

import http.client
import itertools
import logging
import ssl
import struct
from dataclasses import dataclass, field
from urllib.parse import urlsplit

logger = logging.getLogger(__name__)

PRINT_JOB = 0x0002
GET_PRINTER_ATTRIBUTES = 0x000B

TAG_OPERATION = 0x01
TAG_JOB = 0x02
TAG_END = 0x03

VALUE_INTEGER = 0x21
VALUE_BOOLEAN = 0x22
VALUE_ENUM = 0x23
VALUE_RESOLUTION = 0x32
VALUE_RANGE = 0x33
VALUE_BEGIN_COLLECTION = 0x34
VALUE_TEXT_LANG = 0x35
VALUE_NAME_LANG = 0x36
VALUE_END_COLLECTION = 0x37
VALUE_NAME = 0x42
VALUE_KEYWORD = 0x44
VALUE_URI = 0x45
VALUE_CHARSET = 0x47
VALUE_LANGUAGE = 0x48
VALUE_MIME = 0x49

STATUS_VERSION_NOT_SUPPORTED = 0x0503

# Asked for when looking at a printer: what it accepts, and in which raster
# variants. Asking for specific attributes keeps the answer small.
WANTED_ATTRIBUTES = (
    "printer-make-and-model",
    "printer-info",
    "printer-name",
    "printer-state",
    "document-format-supported",
    "pwg-raster-document-resolution-supported",
    "pwg-raster-document-type-supported",
    "urf-supported",
    "color-supported",
    "sides-supported",
    "media-default",
    "media-supported",
)

_request_ids = itertools.count(1)


class IppError(RuntimeError):
    """The printer could not be reached or refused the request."""


@dataclass(frozen=True)
class Resolution:
    x: int
    y: int
    units: int  # 3 = dots per inch, 4 = dots per centimetre

    @property
    def dpi(self) -> tuple[int, int]:
        if self.units == 4:
            return round(self.x * 2.54), round(self.y * 2.54)
        return self.x, self.y


@dataclass
class Response:
    status: int
    attributes: dict[str, list] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        # 0x0000-0x00FF are the successful status codes.
        return self.status < 0x0100

    def first(self, name: str, default=None):
        values = self.attributes.get(name)
        return values[0] if values else default


# --- encoding ------------------------------------------------------------------


def _attribute(tag: int, name: str, values) -> bytes:
    if not isinstance(values, (list, tuple)):
        values = [values]
    out = b""
    for index, value in enumerate(values):
        if tag in (VALUE_INTEGER, VALUE_ENUM):
            encoded = struct.pack(">i", int(value))
        elif tag == VALUE_BOOLEAN:
            encoded = b"\x01" if value else b"\x00"
        else:
            encoded = str(value).encode("utf-8")
        label = name.encode("ascii") if index == 0 else b""
        out += struct.pack(">BH", tag, len(label)) + label
        out += struct.pack(">H", len(encoded)) + encoded
    return out


def encode_request(
    operation: int,
    printer_uri: str,
    operation_attributes: list[tuple[int, str, object]] = (),
    job_attributes: list[tuple[int, str, object]] = (),
    version: tuple[int, int] = (2, 0),
    request_id: int | None = None,
) -> bytes:
    request_id = request_id if request_id is not None else next(_request_ids)
    body = struct.pack(">BBHI", version[0], version[1], operation, request_id)
    body += bytes([TAG_OPERATION])
    # These three must come first, in this order (RFC 8011 4.1.4).
    body += _attribute(VALUE_CHARSET, "attributes-charset", "utf-8")
    body += _attribute(VALUE_LANGUAGE, "attributes-natural-language", "en")
    body += _attribute(VALUE_URI, "printer-uri", printer_uri)
    for tag, name, value in operation_attributes:
        body += _attribute(tag, name, value)
    if job_attributes:
        body += bytes([TAG_JOB])
        for tag, name, value in job_attributes:
            body += _attribute(tag, name, value)
    return body + bytes([TAG_END])


# --- decoding ------------------------------------------------------------------


def _decode_value(tag: int, raw: bytes):
    if tag in (VALUE_INTEGER, VALUE_ENUM) and len(raw) == 4:
        return struct.unpack(">i", raw)[0]
    if tag == VALUE_BOOLEAN and len(raw) == 1:
        return raw != b"\x00"
    if tag == VALUE_RESOLUTION and len(raw) == 9:
        x, y, units = struct.unpack(">iiB", raw)
        return Resolution(x, y, units)
    if tag == VALUE_RANGE and len(raw) == 8:
        return struct.unpack(">ii", raw)
    if tag in (VALUE_TEXT_LANG, VALUE_NAME_LANG) and len(raw) >= 4:
        lang_length = struct.unpack(">H", raw[:2])[0]
        start = 2 + lang_length + 2
        return raw[start:].decode("utf-8", "replace")
    if tag < 0x20:  # out-of-band: unknown, no-value, ...
        return None
    return raw.decode("utf-8", "replace")


def decode_response(data: bytes) -> Response:
    """Parse an IPP response into status and a flat attribute dictionary.

    Collections (media-col and friends) are skipped: nothing here needs them,
    and parsing them correctly is most of the complexity of the format.
    """
    if len(data) < 9:
        raise IppError("Antwort des Druckers ist zu kurz - ist das wirklich ein IPP-Drucker?")
    _version, status, _request_id = struct.unpack(">HHI", data[:8])
    response = Response(status=status)
    offset = 8
    current: str | None = None
    depth = 0
    while offset < len(data):
        tag = data[offset]
        offset += 1
        if tag == TAG_END:
            break
        if tag < 0x10:  # a new attribute group
            current = None
            continue
        if offset + 2 > len(data):
            break
        name_length = struct.unpack(">H", data[offset : offset + 2])[0]
        offset += 2
        name = data[offset : offset + name_length].decode("utf-8", "replace")
        offset += name_length
        if offset + 2 > len(data):
            break
        value_length = struct.unpack(">H", data[offset : offset + 2])[0]
        offset += 2
        raw = data[offset : offset + value_length]
        offset += value_length

        if tag == VALUE_BEGIN_COLLECTION:
            if depth == 0 and name:
                response.attributes.setdefault(name, []).append(None)
            depth += 1
            continue
        if tag == VALUE_END_COLLECTION:
            depth = max(0, depth - 1)
            continue
        if depth:
            continue
        if name:
            current = name
        if current is None:
            continue
        response.attributes.setdefault(current, []).append(_decode_value(tag, raw))
    return response


# --- transport -----------------------------------------------------------------


def split_uri(uri: str) -> tuple[str, str, int, str]:
    """(scheme, host, port, path) of an ipp:// or ipps:// address."""
    parts = urlsplit(uri.strip())
    scheme = parts.scheme.lower()
    if scheme not in ("ipp", "ipps") or not parts.hostname:
        raise IppError(f"{uri!r} ist keine Druckeradresse der Form ipp://<adresse>/ipp/print")
    return scheme, parts.hostname, parts.port or 631, parts.path or "/"


def _post(uri: str, body: bytes, timeout: float) -> bytes:
    scheme, host, port, path = split_uri(uri)
    if scheme == "ipps":
        # Printers ship self-signed certificates; there is nothing to verify
        # them against. The connection is still encrypted.
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        connection = http.client.HTTPSConnection(host, port, timeout=timeout, context=context)
    else:
        connection = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        connection.request(
            "POST", path, body=body,
            headers={"Content-Type": "application/ipp", "Accept": "application/ipp"},
        )
        reply = connection.getresponse()
        data = reply.read()
        if reply.status != 200:
            raise IppError(f"Drucker antwortet mit HTTP {reply.status} {reply.reason}")
        return data
    except (OSError, http.client.HTTPException) as exc:
        raise IppError(f"Drucker {host}:{port} nicht erreichbar: {exc}") from exc
    finally:
        connection.close()


def _call(uri: str, operation: int, timeout: float, operation_attributes=(),
          job_attributes=(), document: bytes = b"") -> Response:
    """Send one request; retry as IPP/1.1 for printers that only speak that."""
    for version in ((2, 0), (1, 1)):
        body = encode_request(operation, uri, operation_attributes, job_attributes, version)
        response = decode_response(_post(uri, body + document, timeout))
        if response.status != STATUS_VERSION_NOT_SUPPORTED:
            return response
    return response


def printer_attributes(uri: str, timeout: float = 10) -> Response:
    response = _call(
        uri, GET_PRINTER_ATTRIBUTES, timeout,
        operation_attributes=[
            (VALUE_NAME, "requesting-user-name", "mail2nas"),
            (VALUE_KEYWORD, "requested-attributes", list(WANTED_ATTRIBUTES)),
        ],
    )
    if not response.ok:
        raise IppError(f"Drucker lehnt die Abfrage ab (IPP-Status 0x{response.status:04x})")
    return response


def print_job(
    uri: str,
    document: bytes,
    document_format: str,
    job_name: str,
    job_attributes: list[tuple[int, str, object]] = (),
    timeout: float = 120,
) -> int | None:
    """Send one document. Returns the job id the printer assigned."""
    response = _call(
        uri, PRINT_JOB, timeout,
        operation_attributes=[
            (VALUE_NAME, "requesting-user-name", "mail2nas"),
            (VALUE_NAME, "job-name", job_name[:255] or "mail2nas"),
            (VALUE_MIME, "document-format", document_format),
        ],
        job_attributes=list(job_attributes),
        document=document,
    )
    if not response.ok:
        message = response.first("status-message") or ""
        raise IppError(
            f"Drucker hat den Auftrag abgelehnt (IPP-Status 0x{response.status:04x})"
            + (f": {message}" if message else "")
        )
    return response.first("job-id")
