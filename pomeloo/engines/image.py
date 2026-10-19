"""Raster/SVG images via Pillow (+pillow-heif for HEIC, PyMuPDF for SVG)."""
from pathlib import Path

import pymupdf as fitz
from PIL import Image, ImageOps
import pillow_heif

pillow_heif.register_heif_opener()
if not hasattr(Image, "_avif_registered"):
    try:  # Pillow >= 11.2 ships AVIF natively; older pillow-heif had an opener.
        from PIL import AvifImagePlugin  # noqa: F401
    except ImportError:
        getattr(pillow_heif, "register_avif_opener", lambda: None)()

PIL_FORMAT = {"jpg": "JPEG", "png": "PNG", "webp": "WEBP", "heic": "HEIF", "tiff": "TIFF",
              "avif": "AVIF", "bmp": "BMP", "pdf": "PDF", "gif": "GIF"}


def open_image(src) -> Image.Image:
    src = Path(src)
    if src.suffix.lower() == ".svg":
        page = fitz.open(src)[0]
        zoom = max(1.0, 2000 / max(page.rect.width, page.rect.height, 1))  # ~2000px long side
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=True)
        return Image.frombytes("RGBA", (pix.width, pix.height), pix.samples)
    img = Image.open(src)
    img.load()
    return ImageOps.exif_transpose(img)


def flatten(img: Image.Image, bg=(255, 255, 255)) -> Image.Image:
    """Drop alpha onto a solid background (for JPEG/PDF/BMP)."""
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        out = Image.new("RGB", rgba.size, bg)
        out.paste(rgba, mask=rgba.getchannel("A"))
        return out
    return img.convert("RGB")


def save_image(img: Image.Image, dst, ext: str, quality: int = 90, exif: bytes | None = None):
    kw = {}
    if ext in ("jpg", "pdf", "bmp"):
        img = flatten(img)
    elif img.mode not in ("RGB", "RGBA", "L", "LA", "1", "P"):
        img = img.convert("RGBA" if "A" in img.mode else "RGB")
    if ext in ("heic", "avif") and img.mode not in ("RGB", "RGBA"):
        img = img.convert("RGBA" if "A" in img.getbands() or img.mode == "P" else "RGB")
    if ext == "jpg":
        kw = {"quality": quality, "optimize": True, "progressive": True}
    elif ext in ("webp", "heic", "avif"):
        kw = {"quality": quality}
    elif ext == "png":
        kw = {"optimize": True}
    elif ext == "tiff":
        kw = {"compression": "tiff_lzw"}
    elif ext == "pdf":
        kw = {"resolution": 300.0}
    if exif and ext in ("jpg", "webp", "png", "tiff", "heic", "avif"):
        kw["exif"] = exif
    img.save(dst, PIL_FORMAT[ext], **kw)


def exif_bytes(img: Image.Image) -> bytes | None:
    try:
        ex = img.getexif()
        return ex.tobytes() if len(ex) else None
    except Exception:
        return None


def convert(src: Path, dst: Path, target: str):
    img = open_image(src)
    save_image(img, dst, target, exif=exif_bytes(img))
