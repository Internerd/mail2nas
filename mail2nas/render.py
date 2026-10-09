"""Turning an attachment into something a printer accepts.

Two steps, used by direct IPP printing (`ipp.py`):

1. **Anything -> PDF.** PDF stays as it is, PostScript goes through
   Ghostscript, images through Pillow, plain text through a tiny PDF writer
   below. PDF is the common ground every later step understands.
2. **PDF -> raster**, only if the printer cannot take PDF itself: Ghostscript
   renders PWG raster (IPP Everywhere, Mopria) or URF (AirPrint) at a
   resolution the printer listed as supported.

Ghostscript always runs with -dSAFER: the documents are mail attachments from
strangers, and PostScript/PDF are programming languages.
"""
from __future__ import annotations

import io
import logging
import os
import subprocess
import tempfile

logger = logging.getLogger(__name__)

TEXT_EXTENSIONS = {"txt", "text", "log", "csv"}
IMAGE_EXTENSIONS = {"png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff"}

# Page sizes in PostScript points, and the names Ghostscript uses for them.
PAGE_SIZES = {"a4": (595, 842), "letter": (612, 792)}

# Only TIFF is a multi-page document; the frames of a GIF/PNG are an
# animation (think of a spinning logo in a mail signature) and would each
# become a printed page.
MULTIPAGE_IMAGE_FORMATS = {"TIFF"}
MAX_IMAGE_PAGES = 50

# Plain text layout: Courier 10 pt, 2 cm margins.
_FONT_SIZE = 10
_LINE_HEIGHT = 12
_MARGIN = 57
_COLUMNS = 95


class RenderError(RuntimeError):
    """The document could not be prepared for printing."""


# --- to PDF -----------------------------------------------------------------------


def to_pdf(data: bytes, extension: str, paper: str = "a4", gs_binary: str = "gs",
           timeout: int = 120) -> bytes:
    extension = (extension or "").lower()
    if extension == "pdf" or data[:5] == b"%PDF-":
        return data
    if extension == "ps" or data[:2] == b"%!":
        return _ghostscript(data, "ps", ["-sDEVICE=pdfwrite"], paper, gs_binary, timeout)
    if extension in IMAGE_EXTENSIONS:
        return image_to_pdf(data, paper)
    if extension in TEXT_EXTENSIONS:
        return text_to_pdf(decode_text(data), paper)
    raise RenderError(f"Dateityp .{extension or '?'} kann nicht direkt gedruckt werden.")


def decode_text(data: bytes) -> str:
    """UTF-8 if it is, otherwise Windows-1252 - what a German CSV export or
    an older .txt usually is - instead of turning every umlaut into "?"."""
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp1252", "replace")


def _flatten(frame):
    """RGB on white. Converting a transparent image straight to RGB turns the
    transparent area black - a page full of toner for a logo."""
    from PIL import Image

    if frame.mode in ("RGBA", "LA") or (frame.mode == "P" and "transparency" in frame.info):
        rgba = frame.convert("RGBA")
        background = Image.new("RGB", rgba.size, "white")
        background.paste(rgba, mask=rgba.getchannel("A"))
        return background
    return frame.convert("RGB")


def image_to_pdf(data: bytes, paper: str = "a4") -> bytes:
    """One image, scaled to fit the page."""
    try:
        from PIL import Image, ImageSequence
    except ImportError:  # pragma: no cover - Pillow is in requirements.txt
        raise RenderError("Bilder koennen nicht gedruckt werden: Pillow fehlt.") from None

    width_pt, height_pt = PAGE_SIZES.get(paper, PAGE_SIZES["a4"])
    try:
        image = Image.open(io.BytesIO(data))
        if image.format in MULTIPAGE_IMAGE_FORMATS:
            frames = [_flatten(frame) for _, frame in
                      zip(range(MAX_IMAGE_PAGES), ImageSequence.Iterator(image))]
        else:
            frames = [_flatten(image)]
    except Exception as exc:  # noqa: BLE001 - Pillow raises many types for broken files
        raise RenderError(f"Bild nicht lesbar: {exc}") from exc
    if not frames:
        raise RenderError("Bild enthaelt keine Seite.")
    # The resolution decides the size on paper: chosen so the largest image
    # just fits the printable area. Small images are not blown up beyond 150 dpi.
    usable_w = (width_pt - 2 * _MARGIN) / 72
    usable_h = (height_pt - 2 * _MARGIN) / 72
    resolution = max(150.0, max(max(f.width / usable_w, f.height / usable_h) for f in frames))
    out = io.BytesIO()
    frames[0].save(out, "PDF", resolution=resolution, save_all=True, append_images=frames[1:])
    return out.getvalue()


def _pdf_string(text: str) -> bytes:
    # The base-14 Courier speaks Latin-1 (WinAnsi); anything else becomes "?".
    raw = text.encode("cp1252", "replace")
    return b"(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)") + b")"


def _wrap(text: str) -> list[str]:
    lines: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = line.expandtabs(4).replace("\f", "")
        line = "".join(ch for ch in line if ch.isprintable())
        while len(line) > _COLUMNS:
            lines.append(line[:_COLUMNS])
            line = line[_COLUMNS:]
        lines.append(line)
    while lines and not lines[-1]:
        lines.pop()
    return lines or [""]


def text_to_pdf(text: str, paper: str = "a4") -> bytes:
    """Plain text as a PDF in Courier - enough for test pages and CSV dumps."""
    width, height = PAGE_SIZES.get(paper, PAGE_SIZES["a4"])
    per_page = max(1, (height - 2 * _MARGIN) // _LINE_HEIGHT)
    lines = _wrap(text)
    pages = [lines[i : i + per_page] for i in range(0, len(lines), per_page)]

    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"",  # the page tree, filled in below once the page ids are known
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
    ]
    page_ids = []
    for page in pages:
        stream = [b"BT", f"/F1 {_FONT_SIZE} Tf {_LINE_HEIGHT} TL".encode(),
                  f"{_MARGIN} {height - _MARGIN - _FONT_SIZE} Td".encode()]
        for line in page:
            stream.append(_pdf_string(line) + b" Tj T*")
        stream.append(b"ET")
        content = b"\n".join(stream)
        objects.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
        content_id = len(objects)
        objects.append(
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            b"/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>"
            % (width, height, content_id)
        )
        page_ids.append(len(objects))
    kids = b" ".join(b"%d 0 R" % pid for pid in page_ids)
    objects[1] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(page_ids))

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1, xref)
    return bytes(out)


# --- to raster ----------------------------------------------------------------------


def to_pwg_raster(pdf: bytes, dpi: int = 300, color: bool = False, paper: str = "a4",
                  gs_binary: str = "gs", timeout: int = 120, output: str | None = None):
    # cupsColorSpace 18 = sGray, 19 = sRGB; 8 bits per colour are what IPP
    # Everywhere requires every printer to accept (sgray_8 / srgb_8).
    args = ["-sDEVICE=pwgraster", f"-r{dpi}", f"-dcupsColorSpace={19 if color else 18}",
            "-dcupsBitsPerColor=8"]
    return _ghostscript(pdf, "pdf", args, paper, gs_binary, timeout, output)


def to_urf(pdf: bytes, dpi: int = 300, paper: str = "a4", gs_binary: str = "gs",
           timeout: int = 120, output: str | None = None):
    return _ghostscript(pdf, "pdf", ["-sDEVICE=urf", f"-r{dpi}"], paper, gs_binary, timeout,
                        output)


def _ghostscript(data: bytes, suffix: str, device_args: list[str], paper: str,
                 gs_binary: str, timeout: int, output: str | None = None):
    """Run Ghostscript. Returns the result as bytes - or, with `output`, writes
    it to that path and returns the path: a raster of a long document runs to
    hundreds of megabytes and must not be held in memory on a small LXC."""
    with tempfile.TemporaryDirectory(prefix="mail2nas-render-") as workdir:
        source = os.path.join(workdir, f"in.{suffix}")
        target = output or os.path.join(workdir, "out")
        with open(source, "wb") as fh:
            fh.write(data)
        command = [
            gs_binary, "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dNOINTERPOLATE",
            f"-sPAPERSIZE={paper if paper in PAGE_SIZES else 'a4'}", "-dFIXEDMEDIA",
            "-dPDFFitPage", *device_args, f"-sOutputFile={target}", source,
        ]
        try:
            result = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
        except FileNotFoundError:
            raise RenderError(
                f"{gs_binary} nicht gefunden - im Container fehlt das Paket ghostscript."
            ) from None
        except subprocess.TimeoutExpired:
            raise RenderError(f"Aufbereiten fuer den Drucker nach {timeout}s abgebrochen.") from None
        if result.returncode != 0 or not os.path.exists(target):
            message = (result.stderr or result.stdout or b"").decode("utf-8", "replace").strip()
            raise RenderError(f"Ghostscript konnte das Dokument nicht aufbereiten: "
                              f"{message[-300:] or result.returncode}")
        if output:
            return output
        with open(target, "rb") as fh:
            return fh.read()
