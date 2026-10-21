"""PDF and archive tools (PyMuPDF / stdlib)."""
from pathlib import Path

import pymupdf as fitz

from ..catalog import stem_of

# (jpeg quality, target dpi) from gentle to aggressive
_LEVELS = [(80, 150), (65, 120), (50, 96), (35, 72), (25, 50)]


def _save(doc, dst):
    doc.save(dst, garbage=4, deflate=True, clean=True)


def compress(src: Path, dst: Path, percent=50, target_kb=0):
    target = target_kb * 1024 if target_kb else src.stat().st_size * percent / 100
    start = 0 if percent >= 75 else 1 if percent >= 50 else 2
    for q, dpi in _LEVELS[start:]:
        doc = fitz.open(src)
        doc.rewrite_images(dpi_threshold=dpi + 10, dpi_target=dpi, quality=q)
        _save(doc, dst)
        if dst.stat().st_size <= target:
            break
    return dst


def metadata(src: Path, dst: Path, mode="remove", fields=None):
    doc = fitz.open(src)
    if mode == "remove":
        doc.set_metadata({})
        doc.del_xml_metadata()
    else:
        meta = dict(doc.metadata or {})
        fields = {k.rpartition("/")[2].lower(): v for k, v in (fields or {}).items()}
        meta.update({k: v for k, v in fields.items()
                     if k in ("title", "author", "subject", "keywords", "creator", "producer")})
        doc.set_metadata(meta)
    _save(doc, dst)
    return dst


def read_metadata(src: Path) -> dict:
    return {k: v for k, v in (fitz.open(src).metadata or {}).items() if v}


def _parse_ranges(spec: str, n: int) -> list[list[int]]:
    """'1-3, 5' -> [[0,1,2],[4]]; empty -> every page on its own."""
    if not spec.strip():
        return [[i] for i in range(n)]
    out = []
    for part in spec.split(","):
        a, _, b = part.strip().partition("-")
        lo, hi = int(a), int(b or a)
        out.append([i - 1 for i in range(lo, hi + 1) if 1 <= i <= n])
    return [r for r in out if r]


def split(src: Path, folder: Path, ranges=""):
    doc = fitz.open(src)
    folder.mkdir()
    for k, pages in enumerate(_parse_ranges(ranges, len(doc)), 1):
        part = fitz.open()
        for p in pages:
            part.insert_pdf(doc, from_page=p, to_page=p)
        _save(part, folder / f"{stem_of(src)} {k}.pdf")
    return folder


def organize(src: Path, dst: Path, order=None, rotations=None):
    """order: 0-based source page indexes in the new order; omitted pages are removed and
    repeated indexes duplicate a page. rotations: {output position: degrees}."""
    doc = fitz.open(src)
    if order is not None:
        out = fitz.open()
        for i in order:  # insert one by one so duplicates become independent pages
            out.insert_pdf(doc, from_page=int(i), to_page=int(i))
        doc = out
    for pos, deg in (rotations or {}).items():
        page = doc[int(pos)]
        page.set_rotation((page.rotation + int(deg)) % 360)
    _save(doc, dst)
    return dst


def merge(srcs, dst: Path):
    out = fitz.open()
    for s in srcs:
        out.insert_pdf(fitz.open(s))
    _save(out, dst)
    return dst


def extract_archive(src: Path, folder: Path):
    from ..engines.misc import extract
    extract(src, folder)
    return folder


# ---------- passwords, stamps ----------
def protect(src: Path, dst: Path, password=""):
    if not password:
        raise ValueError("Type a password.")
    doc = fitz.open(src)
    doc.save(dst, garbage=4, deflate=True, encryption=fitz.PDF_ENCRYPT_AES_256,
             user_pw=password, owner_pw=password)
    return dst


def unlock(src: Path, dst: Path, password=""):
    doc = fitz.open(src)
    if doc.needs_pass and not doc.authenticate(password):
        raise ValueError("Wrong password." if password else "This PDF needs its password.")
    _save(doc, dst)  # saved without encryption
    return dst


def _rgb(hex_color: str):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def watermark(src: Path, dst: Path, text="CONFIDENTIAL", size=70, opacity=25, angle=45, color="#ff0000"):
    """Text across the middle of every page; size = text width as a % of the page width."""
    text = text or "CONFIDENTIAL"
    doc = fitz.open(src)
    for page in doc:
        r = page.rect
        fs = max(6.0, r.width * size / 100 / fitz.get_text_length(text, fontname="helv", fontsize=1))
        width = fitz.get_text_length(text, fontname="helv", fontsize=fs)
        c = fitz.Point(r.width / 2, r.height / 2)
        page.insert_text(c - (width / 2, -fs / 3), text, fontname="helv", fontsize=fs, color=_rgb(color),
                         fill_opacity=opacity / 100, morph=(c, fitz.Matrix(-float(angle))), overlay=True)
    _save(doc, dst)
    return dst


_NUMBER_FORMATS = {"1": "{n}", "Page 1": "Page {n}", "1 / 10": "{n} / {total}", "Page 1 of 10": "Page {n} of {total}"}


def numbers(src: Path, dst: Path, style="1 / 10", position="bottom center", start=1, size=10):
    doc = fitz.open(src)
    fmt = _NUMBER_FORMATS.get(style, "{n}")
    for i, page in enumerate(doc):
        text = fmt.format(n=start + i, total=start + len(doc) - 1)
        r, m = page.rect, 28
        w = fitz.get_text_length(text, fontname="helv", fontsize=size)
        vert, horiz = position.split()
        x = {"left": m, "center": (r.width - w) / 2, "right": r.width - m - w}[horiz]
        y = m + size if vert == "top" else r.height - m  # baseline: text sits inside the margin at any size
        page.insert_text((x, y), text, fontname="helv", fontsize=size, color=(0.25, 0.25, 0.25), overlay=True)
    _save(doc, dst)
    return dst


# ---------- text (Windows OCR) ----------
def _page_image(page, dpi=200):
    from PIL import Image
    pix = page.get_pixmap(dpi=dpi)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def extract_text(src: Path) -> str:
    """Text of an image (OCR) or a PDF (its text layer, OCR for scanned pages). Goes to the clipboard."""
    from .detect import ocr_text
    if src.suffix.lower() != ".pdf":
        from ..engines.image import open_image
        return ocr_text(open_image(src))
    pages = [p.get_text().strip() or ocr_text(_page_image(p)) for p in fitz.open(src)]
    return "\n\n".join(t for t in pages if t)


def _add_text_layer(page, lines):
    """Invisible OCR words over the page, each stretched to its box, so search and select line up."""
    r = page.rect
    for line in lines:
        for word, (x, y, w, h) in line:
            x, y, w, h = r.x0 + x * r.width, r.y0 + y * r.height, w * r.width, h * r.height
            fs = max(1.0, h * 0.95)
            natural = fitz.get_text_length(word, fontname="helv", fontsize=fs) or 1
            p = fitz.Point(x, y + h * 0.8)
            page.insert_text(p, word, fontname="helv", fontsize=fs, render_mode=3,  # 3 = invisible
                             morph=(p, fitz.Matrix(w / natural, 1)))


def searchable(src: Path, dst: Path):
    """Scanned PDF or photo -> PDF whose text can be searched, selected and copied."""
    from .detect import ocr
    if src.suffix.lower() == ".pdf":
        doc = fitz.open(src)
        for page in doc:
            if not page.get_text().strip():  # only pages without real text
                _add_text_layer(page, ocr(_page_image(page)))
    else:
        from ..engines.image import open_image
        import io
        img = open_image(src).convert("RGB")
        doc = fitz.open()
        page = doc.new_page(width=img.width * 0.75, height=img.height * 0.75)  # 96 dpi -> points
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=90)
        page.insert_image(page.rect, stream=buf.getvalue())
        _add_text_layer(page, ocr(img))
    _save(doc, dst)
    return dst
