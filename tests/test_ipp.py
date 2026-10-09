from __future__ import annotations

import shutil
import struct
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from mail2nas import ipp, printing, render
from mail2nas.printers import Printer, PrinterError, validate
from mail2nas.printing import PrintError, Spooler

needs_gs = pytest.mark.skipif(shutil.which("gs") is None, reason="ghostscript not installed")


def _printer(destination="ipp://10.0.0.5/ipp/print", options="", copies=1) -> Printer:
    return Printer(id=1, name="Brother", destination=destination, server="",
                   options=options, copies=copies, enabled=True)


def _response_bytes(status: int, attributes: list[tuple[int, str, list]]) -> bytes:
    """An IPP response as a printer would send it."""
    out = struct.pack(">BBHI", 2, 0, status, 1) + bytes([ipp.TAG_OPERATION])
    out += ipp._attribute(ipp.VALUE_CHARSET, "attributes-charset", "utf-8")
    out += ipp._attribute(ipp.VALUE_LANGUAGE, "attributes-natural-language", "en")
    out += bytes([0x04])  # printer attributes
    for tag, name, values in attributes:
        if tag == ipp.VALUE_RESOLUTION:
            for index, (x, y) in enumerate(values):
                label = name.encode() if index == 0 else b""
                raw = struct.pack(">iiB", x, y, 3)
                out += struct.pack(">BH", tag, len(label)) + label + struct.pack(">H", 9) + raw
        else:
            out += ipp._attribute(tag, name, values)
    return out + bytes([ipp.TAG_END])


# --- protocol ---------------------------------------------------------------------


def test_a_request_starts_with_the_mandatory_attributes():
    body = ipp.encode_request(ipp.GET_PRINTER_ATTRIBUTES, "ipp://h/ipp/print", request_id=7)

    version, operation, request_id = struct.unpack(">HHI", body[:8])
    assert (version, operation, request_id) == (0x0200, ipp.GET_PRINTER_ATTRIBUTES, 7)
    assert body[8] == ipp.TAG_OPERATION
    assert body.index(b"attributes-charset") < body.index(b"printer-uri")
    assert body.endswith(bytes([ipp.TAG_END]))


def test_a_response_is_decoded_with_multiple_values_and_resolutions():
    data = _response_bytes(0, [
        (ipp.VALUE_MIME, "document-format-supported", ["image/pwg-raster", "image/urf"]),
        (ipp.VALUE_RESOLUTION, "pwg-raster-document-resolution-supported", [(300, 300), (600, 600)]),
        (ipp.VALUE_BOOLEAN, "color-supported", [False]),
        (ipp.VALUE_ENUM, "printer-state", [3]),
    ])

    response = ipp.decode_response(data)

    assert response.ok
    assert response.attributes["document-format-supported"] == ["image/pwg-raster", "image/urf"]
    assert [r.dpi for r in response.attributes["pwg-raster-document-resolution-supported"]] == [
        (300, 300), (600, 600)]
    assert response.first("color-supported") is False
    assert response.first("printer-state") == 3


def test_collections_are_skipped_without_losing_what_follows():
    data = struct.pack(">BBHI", 2, 0, 0, 1) + bytes([0x04])
    data += struct.pack(">BH", ipp.VALUE_BEGIN_COLLECTION, 9) + b"media-col" + struct.pack(">H", 0)
    data += struct.pack(">BH", 0x4A, 0) + struct.pack(">H", 10) + b"media-size"
    data += struct.pack(">BH", ipp.VALUE_BEGIN_COLLECTION, 0) + struct.pack(">H", 0)
    data += struct.pack(">BH", ipp.VALUE_END_COLLECTION, 0) + struct.pack(">H", 0)
    data += struct.pack(">BH", ipp.VALUE_END_COLLECTION, 0) + struct.pack(">H", 0)
    data += ipp._attribute(ipp.VALUE_KEYWORD, "sides-supported", ["one-sided"])
    data += bytes([ipp.TAG_END])

    response = ipp.decode_response(data)

    assert response.attributes["sides-supported"] == ["one-sided"]
    assert "media-size" not in response.attributes


@pytest.mark.parametrize("data", [b"", b"\x02\x00", b"\x02\x00\x00\x00\x00\x00\x00\x01\x01\x44\xff"])
def test_garbage_does_not_crash_the_decoder(data):
    try:
        ipp.decode_response(data)
    except ipp.IppError:
        pass


@pytest.mark.parametrize("uri", ["http://x/ipp", "ipp://", "10.0.0.5"])
def test_only_ipp_addresses_are_accepted(uri):
    with pytest.raises(ipp.IppError):
        ipp.split_uri(uri)


def test_the_default_port_is_631():
    assert ipp.split_uri("ipp://10.0.0.5/ipp/print") == ("ipp", "10.0.0.5", 631, "/ipp/print")
    assert ipp.split_uri("ipps://drucker:443/x")[2] == 443


def test_a_job_really_goes_over_http():
    """End to end through the socket: a tiny HTTP server playing printer."""
    received = {}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 - name required by http.server
            length = int(self.headers["Content-Length"])
            received["type"] = self.headers["Content-Type"]
            received["path"] = self.path
            received["body"] = self.rfile.read(length)
            reply = _response_bytes(0, [(ipp.VALUE_INTEGER, "job-id", [42])])
            self.send_response(200)
            self.send_header("Content-Type", "application/ipp")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        uri = f"ipp://127.0.0.1:{server.server_port}/ipp/print"
        job = ipp.print_job(uri, b"%PDF-1.4 fake", "application/pdf", "Rechnung",
                            [(ipp.VALUE_INTEGER, "copies", 2)])
    finally:
        server.shutdown()

    assert job == 42
    assert received["type"] == "application/ipp"
    assert received["path"] == "/ipp/print"
    assert received["body"].endswith(b"%PDF-1.4 fake")
    assert b"application/pdf" in received["body"] and b"copies" in received["body"]


def test_a_document_file_is_streamed_with_the_right_length(tmp_path, monkeypatch):
    import http.client

    document = tmp_path / "job.pwg"
    document.write_bytes(b"RaS2" + b"\x00" * 200_000)
    seen = {}

    class Connection:
        def __init__(self, *args, **kwargs):
            pass

        def request(self, method, path, body, headers):
            seen["length"] = int(headers["Content-Length"])
            seen["sent"] = b"".join(body)

        def getresponse(self):
            class Reply:
                status, reason = 200, "OK"

                def read(self):
                    return _response_bytes(0, [(ipp.VALUE_INTEGER, "job-id", [5])])
            return Reply()

        def close(self):
            pass

    monkeypatch.setattr(http.client, "HTTPConnection", Connection)

    assert ipp.print_job("ipp://h/ipp/print", str(document), "image/pwg-raster", "t") == 5
    assert seen["length"] == len(seen["sent"])
    assert seen["sent"].endswith(document.read_bytes())


def test_a_refused_job_raises_with_the_status():
    reply = _response_bytes(0x040A, [])  # client-error-document-format-not-supported
    with pytest.raises(ipp.IppError, match="0x040a"):
        original = ipp._post
        try:
            ipp._post = lambda uri, body, timeout: reply
            ipp.print_job("ipp://h/ipp/print", b"x", "application/pdf", "t")
        finally:
            ipp._post = original


# --- rendering --------------------------------------------------------------------


def test_text_becomes_a_pdf_with_one_page_per_screenful():
    pdf = render.text_to_pdf("\n".join(f"Zeile {n} äöü" for n in range(150)))

    assert pdf.startswith(b"%PDF-1.4")
    assert pdf.rstrip().endswith(b"%%EOF")
    assert pdf.count(b"/Type /Page ") == 3  # 64 lines per A4 page
    assert b"Zeile 149 \xe4\xf6\xfc" in pdf  # WinAnsi


def test_brackets_and_backslashes_in_text_are_escaped():
    pdf = render.text_to_pdf("a (b) \\ c")

    assert b"(a \\(b\\) \\\\ c) Tj" in pdf


def test_pdf_passes_through_unchanged():
    assert render.to_pdf(b"%PDF-1.7 x", "pdf") == b"%PDF-1.7 x"


def test_an_image_becomes_a_pdf():
    from io import BytesIO

    from PIL import Image

    png = BytesIO()
    Image.new("RGB", (400, 300), "white").save(png, "PNG")

    assert render.to_pdf(png.getvalue(), "png").startswith(b"%PDF")


def test_an_animated_gif_is_one_page_not_one_per_frame():
    """A spinning logo in a signature must not come out as forty sheets."""
    from io import BytesIO

    from PIL import Image

    frames = [Image.new("RGB", (60, 60), color) for color in ("red", "green", "blue") * 10]
    gif = BytesIO()
    frames[0].save(gif, "GIF", save_all=True, append_images=frames[1:])

    pdf = render.to_pdf(gif.getvalue(), "gif")

    assert b"/Count 1\n" in pdf or b"/Count 1 " in pdf or b"/Count 1>" in pdf


def test_a_multipage_tiff_keeps_its_pages():
    from io import BytesIO

    from PIL import Image

    pages = [Image.new("RGB", (60, 60), color) for color in ("red", "green", "blue")]
    tiff = BytesIO()
    pages[0].save(tiff, "TIFF", save_all=True, append_images=pages[1:])

    assert b"/Count 3" in render.to_pdf(tiff.getvalue(), "tif")


def test_transparency_becomes_white_not_black():
    from io import BytesIO

    from PIL import Image

    image = Image.new("RGBA", (10, 10), (0, 0, 0, 0))
    assert render._flatten(image).getpixel((5, 5)) == (255, 255, 255)
    png = BytesIO()
    image.save(png, "PNG")
    assert render.to_pdf(png.getvalue(), "png").startswith(b"%PDF")


def test_a_windows_text_file_keeps_its_umlauts():
    assert render.decode_text("Grüße".encode("cp1252")) == "Grüße"
    assert render.decode_text("\ufeffGrüße".encode("utf-8")) == "Grüße"


def test_unknown_types_are_refused():
    with pytest.raises(render.RenderError):
        render.to_pdf(b"PK\x03\x04", "docx")


@needs_gs
def test_ghostscript_makes_pwg_raster_at_the_wanted_resolution():
    raster = render.to_pwg_raster(render.text_to_pdf("Hallo"), dpi=300)

    assert raster[:4] == b"RaS2"
    header = raster[4:4 + 1796]
    assert struct.unpack(">II", header[276:284]) == (300, 300)
    assert struct.unpack(">I", header[400:404])[0] == 18  # sGray


@needs_gs
def test_ghostscript_makes_urf():
    assert render.to_urf(render.text_to_pdf("Hallo")).startswith(b"UNIRAST")


# --- printing directly ---------------------------------------------------------------


def _fake_printer(monkeypatch, formats, **extra):
    sent = {}
    attributes = {"document-format-supported": formats, **extra}

    def printer_attributes(uri, timeout=10):
        return ipp.Response(0, attributes)

    def print_job(uri, document, document_format, job_name, job_attributes=(), timeout=120):
        sent.update(uri=uri, document=document, format=document_format, name=job_name,
                    attributes={name: value for _, name, value in job_attributes})
        return 7

    monkeypatch.setattr(ipp, "printer_attributes", printer_attributes)
    monkeypatch.setattr(ipp, "print_job", print_job)
    return sent


def test_a_pdf_printer_gets_the_pdf(monkeypatch):
    sent = _fake_printer(monkeypatch, ["application/pdf", "image/pwg-raster"])

    reply = printing.print_direct(_printer(), b"%PDF-1.4 x", "pdf", "Rechnung")

    assert sent["format"] == "application/pdf"
    assert sent["document"] == b"%PDF-1.4 x"
    assert "7" in reply


def test_a_raster_only_printer_gets_pwg_raster_at_a_supported_resolution(monkeypatch):
    sent = _fake_printer(
        monkeypatch, ["application/octet-stream", "image/pwg-raster", "image/urf"],
        **{"pwg-raster-document-resolution-supported": [ipp.Resolution(600, 600, 3),
                                                        ipp.Resolution(1200, 1200, 3)],
           "pwg-raster-document-type-supported": ["black_1", "sgray_8"]},
    )
    calls = {}
    def fake_raster(pdf, dpi, color, paper, gs, timeout, output=None):
        calls.update(dpi=dpi, color=color, paper=paper, to_file=output is not None)
        return output

    monkeypatch.setattr(render, "to_pwg_raster", fake_raster)

    printing.print_direct(_printer(), b"%PDF-1.4 x", "pdf", "Rechnung")

    assert sent["format"] == "image/pwg-raster"
    # the raster is handed over as a file, not as one big bytes object
    assert calls == {"dpi": 600, "color": False, "paper": "a4", "to_file": True}
    assert isinstance(sent["document"], str)


def test_urf_is_the_last_resort(monkeypatch):
    sent = _fake_printer(monkeypatch, ["image/urf"], **{"urf-supported": ["W8", "RS300-600"]})
    calls = {}
    monkeypatch.setattr(render, "to_urf", lambda pdf, dpi, paper, gs, timeout, output=None:
                        calls.update(dpi=dpi) or output)

    printing.print_direct(_printer(), b"%PDF-1.4 x", "pdf", "Rechnung")

    assert sent["format"] == "image/urf"
    assert calls == {"dpi": 300}


def test_a_printer_without_a_usable_format_says_so(monkeypatch):
    _fake_printer(monkeypatch, ["application/vnd.hp-pcl"])

    with pytest.raises(PrintError, match="vnd.hp-pcl"):
        printing.print_direct(_printer(), b"%PDF-1.4 x", "pdf", "Rechnung")


def test_copies_and_supported_options_go_along(monkeypatch):
    sent = _fake_printer(
        monkeypatch, ["application/pdf"],
        **{"sides-supported": ["one-sided", "two-sided-long-edge"],
           "media-supported": ["iso_a4_210x297mm", "na_letter_8.5x11in"]},
    )

    printing.print_direct(
        _printer(options="media=A4 sides=two-sided-long-edge", copies=3), b"%PDF-1.4", "pdf", "t"
    )

    assert sent["attributes"] == {
        "copies": 3, "sides": "two-sided-long-edge", "media": "iso_a4_210x297mm"}


def test_an_unreachable_printer_is_a_print_error(monkeypatch):
    def unreachable(uri, timeout=10):
        raise ipp.IppError("Drucker 10.0.0.5:631 nicht erreichbar: timed out")

    monkeypatch.setattr(ipp, "printer_attributes", unreachable)

    with pytest.raises(PrintError, match="nicht erreichbar"):
        printing.print_direct(_printer(), b"%PDF-1.4", "pdf", "t")


def test_the_spooler_sends_ipp_addresses_directly_and_never_calls_lp(monkeypatch):
    calls = []
    monkeypatch.setattr(printing, "print_direct",
                        lambda printer, data, ext, title, timeout, gs: calls.append(ext) or "ok")
    spooler = Spooler(lp_binary="/nonexistent/lp")

    spooler.print_test_page(_printer())

    assert calls == ["txt"]


# --- the printer form ------------------------------------------------------------------


def test_an_ipp_address_is_a_valid_destination():
    values = validate({"name": "Brother", "destination": "ipp://10.10.112.160/ipp/print"})

    assert values["destination"] == "ipp://10.10.112.160/ipp/print"


def test_an_ipp_address_with_a_cups_server_is_refused():
    with pytest.raises(PrinterError, match="CUPS-Server bitte leer"):
        validate({"destination": "ipp://10.0.0.5/ipp/print", "server": "cups.lan"})


@pytest.mark.parametrize("destination", ["ipp:///ipp/print", "ipp://host:abc/x"])
def test_a_broken_ipp_address_is_refused(destination):
    with pytest.raises(PrinterError):
        validate({"destination": destination})


def test_is_direct():
    assert _printer().is_direct
    assert _printer("IPPS://drucker/ipp/print").is_direct
    assert not _printer("Kyocera_M2540").is_direct
