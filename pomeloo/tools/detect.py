"""Local face/text detection with the detectors built into Windows (no model downloads).

Returns regions as fractions [x, y, w, h] of the image, ready for redaction.
"""
import asyncio
import threading

from PIL import Image

_MAX = 1600  # detectors are faster on a downscaled copy; boxes are fractions anyway


async def _bitmap(img: Image.Image, gray: bool, keep: list):
    """Decode through BitmapDecoder: bitmaps built from raw buffers crash FaceDetector. The WinRT
    objects go into `keep`, one list per call, so they outlive the detector call (parallel jobs too)."""
    import io
    from winrt.windows.graphics.imaging import BitmapDecoder, BitmapPixelFormat, SoftwareBitmap
    from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "BMP")  # BMP: ~26 ms for a full HD screen vs ~650 ms as PNG
    stream = InMemoryRandomAccessStream()
    w = DataWriter(stream)
    w.write_bytes(buf.getvalue())
    await w.store_async()
    stream.seek(0)
    dec = await BitmapDecoder.create_async(stream)
    bmp = await dec.get_software_bitmap_async()
    out = SoftwareBitmap.convert(bmp, BitmapPixelFormat.GRAY8) if gray else bmp
    keep.extend([stream, w, dec, bmp, out])
    return out


async def _faces(img, keep):
    from winrt.windows.media.faceanalysis import FaceDetector
    if not FaceDetector.is_supported:
        return []
    det = await FaceDetector.create_async()
    return [(f.face_box.x, f.face_box.y, f.face_box.width, f.face_box.height)
            for f in await det.detect_faces_async(await _bitmap(img, True, keep))]


async def _text(img, keep):
    eng = warm_up()
    if eng is None:
        return []
    res = await eng.recognize_async(await _bitmap(img, False, keep))
    return [(r.x, r.y, r.width, r.height) for line in res.lines for r in (w.bounding_rect for w in line.words)]


_engine = []  # the OCR engine is kept: creating it is part of the first-call delay
# ponytail: one recognition at a time on the shared engine (Windows refuses two at once); each
# takes 30-80 ms, so queued jobs barely wait. Per-thread engines if that ever becomes a bottleneck.
_ocr_lock = threading.Lock()


def warm_up():
    """Import WinRT and create the OCR engine ahead of time (the tray app does this once, idle)."""
    from winrt.windows.media.ocr import OcrEngine
    if not _engine:
        _engine.append(OcrEngine.try_create_from_user_profile_languages())
    return _engine[0]


def ocr(img: Image.Image, max_side=4000) -> list[list[tuple[str, list[float]]]]:
    """Windows OCR (the languages of the user's profile): lines of (word, [x, y, w, h] fractions)."""
    small = img.copy()
    small.thumbnail((max_side, max_side))
    W, H = small.size

    keep = []

    async def run():
        eng = warm_up()
        if eng is None:
            raise RuntimeError("Windows has no OCR language installed (Settings > Time & language > Language).")
        res = await eng.recognize_async(await _bitmap(small, False, keep))
        return [[(w.text, [w.bounding_rect.x / W, w.bounding_rect.y / H,
                           w.bounding_rect.width / W, w.bounding_rect.height / H]) for w in line.words]
                for line in res.lines]
    with _ocr_lock:
        return asyncio.run(run())


def ocr_text(img: Image.Image) -> str:
    return join_lines([" ".join(word for word, _ in line) for line in ocr(img)])


def join_lines(lines: list[str]) -> str:
    """Re-flow OCR lines into paragraphs: a line that doesn't end a sentence continues on the next
    one (a trailing hyphen joins the word); short lines, bullets and numbered items stay separate."""
    import re
    out = []
    for line in (l.strip() for l in lines):
        if not line:
            continue
        prev = out[-1] if out else ""
        starts_item = re.match(r"^([-•*·]|\d+[.)]|[a-z][.)])\s", line)
        if prev and not starts_item and not re.search(r"[.!?:;]$", prev) and len(prev) > 30:
            out[-1] = prev[:-1] + line if prev.endswith("-") and line[:1].islower() else prev + " " + line
        else:
            out.append(line)
    return "\n".join(out)


def detect(img: Image.Image, faces=True, text=True, pad=0.15) -> list[list[float]]:
    small = img.copy()
    small.thumbnail((_MAX, _MAX))
    W, H = small.size

    keep = []

    async def run():
        return (await _faces(small, keep) if faces else []) + (await _text(small, keep) if text else [])
    with _ocr_lock:
        boxes = asyncio.run(run())
    out = []
    for x, y, w, h in boxes:  # grow a little so edges are covered
        px, py = w * pad, h * pad
        x0, y0 = max(0, x - px), max(0, y - py)
        x1, y1 = min(W, x + w + px), min(H, y + h + py)
        out.append([x0 / W, y0 / H, (x1 - x0) / W, (y1 - y0) / H])
    return out
