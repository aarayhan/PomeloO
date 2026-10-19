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
