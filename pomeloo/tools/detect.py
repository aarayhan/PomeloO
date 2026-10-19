"""Local face/text detection with the detectors built into Windows (no model downloads).

Returns regions as fractions [x, y, w, h] of the image, ready for redaction.
"""
import asyncio

from PIL import Image

_alive: list = []
_MAX = 1600  # detectors are faster on a downscaled copy; boxes are fractions anyway


async def _bitmap(img: Image.Image, gray: bool):
    """Decode through BitmapDecoder: bitmaps built from raw buffers crash FaceDetector."""
    import io
    from winrt.windows.graphics.imaging import BitmapDecoder, BitmapPixelFormat, SoftwareBitmap
    from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream
    png = io.BytesIO()
    img.convert("RGB").save(png, "PNG")
    stream = InMemoryRandomAccessStream()
    w = DataWriter(stream)
    w.write_bytes(png.getvalue())
    await w.store_async()
    stream.seek(0)
    dec = await BitmapDecoder.create_async(stream)
    bmp = await dec.get_software_bitmap_async()
    out = SoftwareBitmap.convert(bmp, BitmapPixelFormat.GRAY8) if gray else bmp
    _alive.extend([stream, w, dec, bmp, out])  # WinRT objects must outlive the detector call
    return out


async def _faces(img):
    from winrt.windows.media.faceanalysis import FaceDetector
    if not FaceDetector.is_supported:
        return []
    det = await FaceDetector.create_async()
    return [(f.face_box.x, f.face_box.y, f.face_box.width, f.face_box.height)
            for f in await det.detect_faces_async(await _bitmap(img, gray=True))]


async def _text(img):
    from winrt.windows.media.ocr import OcrEngine
    eng = OcrEngine.try_create_from_user_profile_languages()
    if eng is None:
        return []
    res = await eng.recognize_async(await _bitmap(img, gray=False))
    return [(r.x, r.y, r.width, r.height) for line in res.lines for r in (w.bounding_rect for w in line.words)]


def detect(img: Image.Image, faces=True, text=True, pad=0.15) -> list[list[float]]:
    small = img.copy()
    small.thumbnail((_MAX, _MAX))
    W, H = small.size

    async def run():
        return (await _faces(small) if faces else []) + (await _text(small) if text else [])
    try:
        boxes = asyncio.run(run())
    finally:
        _alive.clear()
    out = []
    for x, y, w, h in boxes:  # grow a little so edges are covered
        px, py = w * pad, h * pad
        x0, y0 = max(0, x - px), max(0, y - py)
        x1, y1 = min(W, x + w + px), min(H, y + h + py)
        out.append([x0 / W, y0 / H, (x1 - x0) / W, (y1 - y0) / H])
    return out
