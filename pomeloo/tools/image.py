"""Photo tools. Geometry params are fractions of the image (0..1) so the UI and CLI agree."""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

from ..catalog import ext_of
from ..engines.image import exif_bytes, flatten, open_image, save_image

ASPECTS = {"1:1": 1, "4:5": 4 / 5, "4:3": 4 / 3, "3:2": 3 / 2, "16:9": 16 / 9, "9:16": 9 / 16, "3:4": 3 / 4}


def _box(img, rect):
    x, y, w, h = rect
    W, H = img.size
    return (round(x * W), round(y * H), round((x + w) * W), round((y + h) * H))


def _rgb(hexcolor: str):
    h = hexcolor.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _font(size):
    try:
        return ImageFont.truetype("segoeuib.ttf", size)
    except OSError:
        return ImageFont.load_default(size)


def centre_rect(W, H, ratio):
    """Largest centred rect of the given aspect, as fractions."""
    w, h = (W, W / ratio) if W / H < ratio else (H * ratio, H)
    return ((W - w) / 2 / W, (H - h) / 2 / H, w / W, h / H)


# ---------- compress ----------
def compress(src: Path, dst: Path, percent=50, target_kb=0, resize=100):
    target = target_kb * 1024 if target_kb else src.stat().st_size * percent / 100
    img, ext = open_image(src), ext_of(dst)
    if resize and int(resize) < 100:
        f = int(resize) / 100
        img = img.resize((max(1, int(img.width * f)), max(1, int(img.height * f))), Image.LANCZOS)
    if ext in ("jpg", "webp", "heic", "avif"):
        lo, hi, best = 5, 92, None
        while lo <= hi:  # binary search the highest quality that fits
            q = (lo + hi) // 2
            save_image(img, dst, ext, quality=q)
            if dst.stat().st_size <= target:
                best, lo = q, q + 1
            else:
                hi = q - 1
        if best is not None:
            save_image(img, dst, ext, quality=best)
            return dst
        q = 5
    else:
        q = 90
        if ext == "png":  # 256-colour palette usually halves a PNG
            img = img.convert("RGBA").quantize(256, method=Image.Quantize.FASTOCTREE)
        save_image(img, dst, ext)
    while dst.stat().st_size > target and min(img.size) > 32:  # last resort: downscale
        img = img.resize((int(img.width * 0.85), int(img.height * 0.85)), Image.LANCZOS)
        save_image(img, dst, ext, quality=q)
    return dst


# ---------- metadata ----------
def metadata(src: Path, dst: Path, mode="remove", fields=None):
    img = open_image(src)
    if mode == "remove":  # drops EXIF (camera, GPS, processing) and XMP; keeps the colour profile
        img.info = {k: v for k, v in img.info.items() if k == "icc_profile"}
        save_image(img, dst, ext_of(dst))
        return dst
    ex = img.getexif()
    tags = {"title": 0x010E, "imagedescription": 0x010E, "artist": 0x013B, "author": 0x013B,
            "copyright": 0x8298, "make": 0x010F, "model": 0x0110, "software": 0x0131, "datetime": 0x0132}
    for k, v in (fields or {}).items():  # keys may be grouped ("File/Artist")
        if (tag := tags.get(k.rpartition("/")[2].lower())) is not None:
            ex[tag] = v
    save_image(img, dst, ext_of(dst), exif=ex.tobytes())
    return dst


def read_metadata(src: Path) -> dict:
    from PIL.ExifTags import GPSTAGS, IFD, TAGS
    ex = Image.open(src).getexif()
    out = {f"File/{TAGS.get(k, hex(k))}": str(v)[:200] for k, v in ex.items()}
    for ifd, name, names in ((IFD.Exif, "Camera", TAGS), (IFD.GPSInfo, "Location", GPSTAGS)):
        try:
            out.update({f"{name}/{names.get(k, hex(k))}": str(v)[:200] for k, v in ex.get_ifd(ifd).items()})
        except Exception:
            pass
    return out


# ---------- edit ----------
EDIT_DEFAULTS = {"exposure": 0.0, "contrast": 0, "highlights": 0, "shadows": 0, "saturation": 0, "temperature": 0,
                 "tint": 0, "sharpness": 0, "clarity": 0, "dehaze": 0, "noise_reduction": 0, "grain": 0,
                 "vignette": 0, "rotate": 0, "flip": "none", "grayscale": False}


def apply_edit(img: Image.Image, **p) -> Image.Image:
    """Lightroom-style adjustments. Sliders are -100..100 (exposure in stops); 0 = unchanged."""
    p = {**EDIT_DEFAULTS, **p}
    alpha = img.getchannel("A") if "A" in img.getbands() else None
    rgb = img.convert("RGB")
    if p["noise_reduction"]:
        rgb = Image.blend(rgb, rgb.filter(ImageFilter.MedianFilter(5)), min(1, p["noise_reduction"] / 100))
    if p["dehaze"]:
        rgb = Image.blend(rgb, ImageOps.autocontrast(rgb, cutoff=2), min(1, abs(p["dehaze"]) / 100))
    a = np.asarray(rgb, dtype=np.float32) / 255
    a = a * 2 ** float(p["exposure"])
    lum = a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    if p["highlights"]:
        a += (p["highlights"] / 200) * (lum ** 2)[..., None]
    if p["shadows"]:
        a += (p["shadows"] / 200) * ((1 - lum) ** 2)[..., None]
    if p["contrast"]:
        a = (a - 0.5) * (1 + p["contrast"] / 100) + 0.5
    if p["temperature"] or p["tint"]:
        t, g = p["temperature"] / 400, p["tint"] / 400
        a *= np.array([1 + t, 1 - g, 1 - t], dtype=np.float32)
    if p["saturation"] or p["grayscale"]:
        gray = (a @ np.array([0.299, 0.587, 0.114], dtype=np.float32))[..., None]
        s = 0 if p["grayscale"] else 1 + p["saturation"] / 100
        a = gray + (a - gray) * s
    if p["vignette"]:
        h, w = a.shape[:2]
        yy, xx = np.ogrid[:h, :w]
        r = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2) / math.sqrt(2)
        a *= (1 - (p["vignette"] / 100) * r ** 2)[..., None]
    if p["grain"]:
        a += np.random.default_rng(0).normal(0, p["grain"] / 600, a.shape[:2])[..., None].astype(np.float32)
    rgb = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))
    if p["clarity"]:
        rgb = rgb.filter(ImageFilter.UnsharpMask(radius=max(rgb.size) / 80, percent=int(p["clarity"] * 1.2), threshold=2))
    if p["sharpness"]:
        rgb = ImageEnhance.Sharpness(rgb).enhance(1 + p["sharpness"] / 50)
    if alpha:
        rgb.putalpha(alpha)
    if int(p["rotate"]):
        rgb = rgb.rotate(-int(p["rotate"]), expand=True)
    if p["flip"] == "horizontal":
        rgb = ImageOps.mirror(rgb)
    elif p["flip"] == "vertical":
        rgb = ImageOps.flip(rgb)
    return rgb


def edit(src: Path, dst: Path, **p):
    img = open_image(src)
    save_image(apply_edit(img, **p), dst, ext_of(dst), exif=exif_bytes(img))
    return dst


# ---------- annotate ----------
def _arrow(d, a, b, color, width):
    d.line([a, b], fill=color, width=width)
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    size = width * 4
    for s in (-0.45, 0.45):
        d.line([b, (b[0] - size * math.cos(ang + s), b[1] - size * math.sin(ang + s))], fill=color, width=width)


def draw_shapes(img: Image.Image, shapes) -> Image.Image:
    """shapes: [{kind, points:[[x,y],..], color, width, text, n, path}] with fractional coords.
    kinds: pen, highlight, arrow, line, rect, ellipse, number, text, magnify, image."""
    img = img.convert("RGBA")
    W, H = img.size
    scale = max(W, H) / 1000
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    for s in shapes:
        kind, color = s.get("kind", "pen"), s.get("color", "#ff3b30")
        pts = [(x * W, y * H) for x, y in s.get("points", [])]
        width = max(1, round(s.get("width", 6) * scale))
        if not pts:
            continue
        a, b = pts[0], pts[-1]
        box = (min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
        if kind in ("pen", "highlight"):
            fill = _rgb(color) + ((90,) if kind == "highlight" else (255,))
            w = width * (4 if kind == "highlight" else 1)
            if len(pts) > 1:
                d.line(pts, fill=fill, width=w, joint="curve")
            for x, y in (a, b):
                d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=fill)
        elif kind == "arrow":
            _arrow(d, a, b, color, width)
        elif kind == "line":
            d.line([a, b], fill=color, width=width)
        elif kind == "rect":
            d.rectangle(box, outline=color, width=width)
        elif kind == "ellipse":
            d.ellipse(box, outline=color, width=width)
        elif kind == "number":
            r = 18 * scale
            d.ellipse((a[0] - r, a[1] - r, a[0] + r, a[1] + r), fill=color)
            d.text(a, str(s.get("n", 1)), fill="white", font=_font(int(r * 1.2)), anchor="mm")
        elif kind == "text":
            size = max(8, round(s.get("size", 0.05) * max(W, H)))
            d.text(a, s.get("text", ""), fill=color, font=_font(size), stroke_width=max(1, size // 15),
                   stroke_fill="white")
        elif kind == "magnify":  # circle at a showing 2x zoom of what's under it; radius = |b - a|
            r = max(10, math.dist(a, b))
            region = img.crop((int(a[0] - r / 2), int(a[1] - r / 2), int(a[0] + r / 2), int(a[1] + r / 2)))
            zoom = region.resize((int(2 * r), int(2 * r)), Image.LANCZOS)
            mask = Image.new("L", zoom.size, 0)
            ImageDraw.Draw(mask).ellipse((0, 0, *zoom.size), fill=255)
            over.paste(zoom, (int(a[0] - r), int(a[1] - r)), mask)
            d.ellipse((a[0] - r, a[1] - r, a[0] + r, a[1] + r), outline=color, width=width)
        elif kind == "image" and s.get("path"):
            pic = open_image(s["path"]).convert("RGBA")
            pic.thumbnail((max(1, int(box[2] - box[0])), max(1, int(box[3] - box[1]))))
            over.alpha_composite(pic, (int(box[0]), int(box[1])))
    img.alpha_composite(over)
    return img


def annotate(src: Path, dst: Path, shapes=()):
    save_image(draw_shapes(open_image(src), shapes), dst, "png")
    return dst


# ---------- background ----------
def _gradient(size, c1, c2, angle):
    W, H = size
    yy, xx = np.mgrid[:H, :W].astype(np.float32)
    t = math.radians(angle)
    proj = xx * math.cos(t) + yy * math.sin(t)
    proj = (proj - proj.min()) / max(1e-6, proj.max() - proj.min())
    a, b = np.array(_rgb(c1), np.float32), np.array(_rgb(c2), np.float32)
    return Image.fromarray((a + (b - a) * proj[..., None]).astype(np.uint8)).convert("RGBA")


def frame(src: Path, dst: Path, background="color", color="#ffffff", color2="#ff8a00", angle=45,
          image="", aspect="free", padding=8, radius=0, shadow=0, blur=40):
    """Place the photo on a new canvas: solid colour, gradient, another image, or a blurred copy."""
    img = open_image(src).convert("RGBA")
    pad = round(max(img.size) * float(padding) / 100)
    W, H = img.width + 2 * pad, img.height + 2 * pad
    if aspect in ASPECTS:  # grow the canvas to the chosen aspect
        r = ASPECTS[aspect]
        W, H = (max(W, round(H * r)), H) if W / H < r else (W, max(H, round(W / r)))
    if radius:
        mask = Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius=round(min(img.size) * radius / 100), fill=255)
        img.putalpha(Image.composite(img.getchannel("A"), mask, mask))
    if background == "gradient":
        bg = _gradient((W, H), color, color2, float(angle))
    elif background in ("image", "blur"):
        base = open_image(image).convert("RGBA") if background == "image" and image else img
        bg = ImageOps.fit(base, (W, H), Image.LANCZOS)
        if blur:
            bg = bg.filter(ImageFilter.GaussianBlur(max(W, H) * float(blur) / 1000))
    else:
        bg = Image.new("RGBA", (W, H), _rgb(color) + (255,))
    x, y = (W - img.width) // 2, (H - img.height) // 2
    if shadow:
        sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sh.paste((0, 0, 0, int(2.2 * float(shadow))), (x, y + pad // 6), img.getchannel("A"))
        bg.alpha_composite(sh.filter(ImageFilter.GaussianBlur(max(4, pad / 2))))
    bg.alpha_composite(img, (x, y))
    save_image(bg, dst, ext_of(dst))
    return dst


# ---------- crop / redact ----------
def crop(src: Path, dst: Path, rect=None, aspect="free", width=0, height=0):
    """Crop to rect (or centred aspect); width/height > 0 force exact output pixels."""
    img = open_image(src)
    W, H = img.size
    if width and height and not rect:
        rect = centre_rect(W, H, int(width) / int(height))
    elif not rect:
        rect = centre_rect(W, H, ASPECTS.get(aspect, W / H))
    out = img.crop(_box(img, rect))
    if width and height:
        out = ImageOps.fit(out, (int(width), int(height)), Image.LANCZOS)
    save_image(out, dst, ext_of(dst), exif=exif_bytes(img))
    return dst


def redact(src: Path, dst: Path, rects=(), style="pixelate", color="#000000", auto="none"):
    """style: pixelate | blur | color. auto: none | faces | text | both (Windows' local detectors)."""
    img = open_image(src)
    img = img.convert("RGBA" if "A" in img.getbands() else "RGB")
    rects = list(rects)
    if auto != "none":
        from .detect import detect
        rects += detect(img, faces=auto in ("faces", "both"), text=auto in ("text", "both"))
    for rect in rects:
        box = _box(img, rect)
        region = img.crop(box)
        if style in ("color", "black"):
            region = Image.new(img.mode, region.size, "black" if style == "black" else color)
        elif style == "blur":
            region = region.filter(ImageFilter.GaussianBlur(max(region.size) / 6 + 4))
        else:
            small = region.resize((max(1, region.width // 16), max(1, region.height // 16)), Image.BILINEAR)
            region = small.resize(region.size, Image.NEAREST)
        img.paste(region, box[:2])
    save_image(img, dst, ext_of(dst))  # redaction also drops EXIF (could hold GPS)
    return dst


def read_qr(src: Path) -> str:
    import zxingcpp
    found = zxingcpp.read_barcodes(flatten(open_image(src)))
    return "\n".join(b.text for b in found) or "No QR code or barcode found."


# ---------- multi-image ----------
def create_pdf(srcs, dst: Path):
    pages = [flatten(open_image(s)) for s in srcs]
    pages[0].save(dst, "PDF", save_all=True, append_images=pages[1:], resolution=150.0)
    return dst


def _rounded(im, radius):
    if not radius:
        return im
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *im.size), radius=radius, fill=255)
    im.putalpha(Image.composite(im.getchannel("A"), mask, mask))
    return im


def collage(srcs, dst: Path, layout="grid", columns=0, spacing=16, color="#ffffff", cell=600, radius=0, width=0):
    """layout: grid | row | column | featured (first image large on the left)."""
    imgs = [open_image(s).convert("RGBA") for s in srcs]
    sp, cell, rad = int(spacing), int(cell), int(radius)
    tiles = []  # (image, x, y)
    if layout == "row":
        imgs = [im.resize((max(1, round(im.width * cell / im.height)), cell), Image.LANCZOS) for im in imgs]
        x = sp
        for im in imgs:
            tiles.append((im, x, sp))
            x += im.width + sp
        size = (x, cell + 2 * sp)
    elif layout == "column":
        imgs = [im.resize((cell, max(1, round(im.height * cell / im.width))), Image.LANCZOS) for im in imgs]
        y = sp
        for im in imgs:
            tiles.append((im, sp, y))
            y += im.height + sp
        size = (cell + 2 * sp, y)
    elif layout == "featured" and len(imgs) > 1:
        rest = imgs[1:]
        small = (2 * cell + sp - sp * (len(rest) - 1)) // len(rest)
        tiles.append((ImageOps.fit(imgs[0], (2 * cell + sp, 2 * cell + sp), Image.LANCZOS), sp, sp))
        for i, im in enumerate(rest):
            tiles.append((ImageOps.fit(im, (cell, small), Image.LANCZOS), 2 * sp + 2 * cell + sp, sp + i * (small + sp)))
        size = (3 * cell + 4 * sp, 2 * cell + 3 * sp)
    else:
        cols = int(columns) or max(1, round(len(imgs) ** 0.5 + 0.49))
        rows = -(-len(imgs) // cols)
        for i, im in enumerate(imgs):
            r, c = divmod(i, cols)
            tiles.append((ImageOps.fit(im, (cell, cell), Image.LANCZOS), sp + c * (cell + sp), sp + r * (cell + sp)))
        size = (cols * cell + (cols + 1) * sp, rows * cell + (rows + 1) * sp)
    out = Image.new("RGBA", size, _rgb(color) + (255,))
    for im, x, y in tiles:
        out.alpha_composite(_rounded(im, rad), (x, y))
    if width and int(width) != out.width:
        out = out.resize((int(width), round(out.height * int(width) / out.width)), Image.LANCZOS)
    save_image(out, dst, "png")
    return dst
