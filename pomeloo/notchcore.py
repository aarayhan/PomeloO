"""The notch's logic, without UI (pomeloo/ui/notch.py draws it): the shelf that survives restarts,
suggestions for new downloads and screenshots, "fit for" presets, Shift-drag formats, file info for
previews, size savings and battery-saver detection."""
import ctypes
import json
from pathlib import Path

from .catalog import ext_of, kind, size_text, targets, tools
from .shell import APPDIR

SHELF_FILE = APPDIR / "shelf.json"


# ---------- shelf ----------
def load_shelf() -> list[str]:
    try:
        return [p for p in json.loads(SHELF_FILE.read_text(encoding="utf-8")) if Path(p).exists()]
    except (OSError, ValueError):
        return []


def save_shelf(paths):
    APPDIR.mkdir(parents=True, exist_ok=True)
    SHELF_FILE.write_text(json.dumps([str(p) for p in paths], indent=1), encoding="utf-8")


# ---------- suggestions ----------
_MB = 1024 * 1024
# ext -> what people usually want next, as ("convert", fmt) / ("tool", id) / ("fit", preset)
_NEXT = {
    **{e: [("convert", "jpg")] for e in ("heic", "avif", "bmp", "tiff")},
    "webp": [("convert", "jpg"), ("convert", "png")],
    "png": [("convert", "jpg"), ("tool", "extractText")],
    "jpg": [("tool", "extractText"), ("fit", "web")],
    "svg": [("convert", "png")],
    "gif": [("convert", "mp4")],
    **{e: [("convert", "mp4"), ("convert", "mp3")] for e in ("mov", "mkv", "webm", "avi", "wmv")},
    "mp4": [("convert", "mp3"), ("fit", "whatsapp")],
    **{e: [("convert", "mp3")] for e in ("wav", "flac", "m4a", "ogg", "opus", "wma", "aiff")},
    "pdf": [("tool", "extractText"), ("convert", "docx")],
    **{e: [("convert", "pdf")] for e in ("docx", "pptx", "ppt", "md", "epub", "html", "txt")},
    "xls": [("convert", "xlsx")], "csv": [("convert", "xlsx")], "xlsx": [("convert", "pdf")],
    **{e: [("tool", "extractArchive")] for e in ("zip", "rar", "tar", "gz")},
    "srt": [("convert", "vtt")], "vtt": [("convert", "srt")],
}
FIT = {"whatsapp": "WhatsApp", "email": "Email", "web": "Web"}


def label(step) -> str:
    from .catalog import TOOLS
    k, i = step
    return {"convert": f"→ {i.upper()}", "tool": TOOLS.get(i, ("", i))[1], "fit": f"Fit {FIT.get(i, i)}"}[k]


def suggestions(path) -> list[tuple[str, str]]:
    """Next steps that make sense for this file (each one is checked against what PomeloO can do)."""
    p, ext = Path(path), ext_of(path)
    steps = list(_NEXT.get(ext, []))
    try:
        big = p.stat().st_size > 8 * _MB
    except OSError:
        big = False
    if big and "compress" in tools(ext, 1):
        steps.insert(0, ("tool", "compress"))
    ok = []
    for k, i in steps:
        if (k == "convert" and i in targets(ext)) or (k == "tool" and i in tools(ext, 1)) or (k == "fit" and fits(ext, i)):
            ok.append((k, i))
    return ok[:3]


SCREENSHOT_STEPS = [("save", "file"), ("tool", "extractText"), ("tool", "annotateImage"), ("phone", "send")]


# ---------- fit for WhatsApp / email / the web ----------
def fits(ext: str, preset: str) -> bool:
    k = kind(ext)
    if preset == "web":
        return k == "image"
    return k in ("image", "video", "audio") or ext == "pdf"


def fit(path, preset: str) -> list[Path]:
    """Smaller copy for a destination. WhatsApp: photos ~1 MB, video/PDF under its 16 MB media limit;
    Email: under 25 MB; Web: WebP, at most 1920 px wide, ~300 KB. Already small enough: no new file."""
    from .tools import run_tool
    p, ext = Path(path), ext_of(path)
    if not fits(ext, preset):
        raise ValueError(f"{FIT[preset]} size isn't available for {ext.upper()} files.")
    if preset == "web":
        from .engines import convert
        from .engines.image import open_image
        w = open_image(p).width
        webp = convert(p, "webp") if ext != "webp" else p
        out = run_tool("compress", [webp], {"preset": "custom", "target_kb": 300,
                                            "resize": max(10, min(100, int(1920 * 100 / w)))})
        if webp != p:
            webp.unlink(missing_ok=True)
        return [Path(o) for o in out]
    limit_kb = {"whatsapp": 1000 if kind(ext) == "image" else 15_500, "email": 24_000}[preset]
    if p.stat().st_size <= limit_kb * 1024:
        return []
    return [Path(o) for o in run_tool("compress", [p], {"preset": "custom", "target_kb": limit_kb})]


# ---------- Shift-drag: the format a shelf file is dropped as ----------
def drag_format(ext: str) -> str | None:
    k = kind(ext)
    want = ({"image": "jpg" if ext != "jpg" else "png", "video": "mp4" if ext != "mp4" else "gif",
             "audio": "mp3" if ext != "mp3" else "wav"}.get(k)
            or ("docx" if ext == "pdf" else "pdf"))
    return want if want in targets(ext) else None


# ---------- previews, savings, power ----------
def info(path) -> str:
    """One line for the hover preview: dimensions / duration / pages, and size."""
    p, ext = Path(path), ext_of(path)
    bits = []
    try:
        if kind(ext) == "image":
            from .engines.image import open_image
            im = open_image(p)
            bits.append(f"{im.width} × {im.height}")
        elif kind(ext) in ("video", "audio"):
            from .engines.media import probe
            d = probe(p)
            bits.append(f"{int(d['duration'] // 60)}:{int(d['duration'] % 60):02d}")
            if d.get("size"):
                bits.append("{} × {}".format(*d["size"]))
        elif ext == "pdf":
            import pymupdf as fitz
            with fitz.open(p) as doc:
                bits.append(f"{doc.page_count} page{'s' * (doc.page_count != 1)}")
        bits.append(size_text(p.stat().st_size) if p.is_file() else "folder")
    except Exception:
        pass
    return " · ".join(bits)


def savings(sources, outputs) -> str | None:
    """'−62% · 4.1 MB → 1.6 MB' when the results are smaller than the originals."""
    try:
        before = sum(Path(s).stat().st_size for s in sources if Path(s).is_file())
        after = sum(Path(o).stat().st_size for o in outputs if Path(o).is_file())
    except OSError:
        return None
    if not before or not after or after >= before:
        return None
    return f"−{round(100 - after * 100 / before)}% · {size_text(before)} → {size_text(after)}"


class _Power(ctypes.Structure):
    _fields_ = [("ac", ctypes.c_byte), ("flag", ctypes.c_byte), ("percent", ctypes.c_byte),
                ("saver", ctypes.c_byte), ("life", ctypes.c_ulong), ("full", ctypes.c_ulong)]


def battery_saver() -> bool:
    """Windows' battery saver is on: the notch skips its animations."""
    s = _Power()
    return bool(ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s)) and s.saver & 1)


if __name__ == "__main__":  # self-check of the pure parts
    assert suggestions("x.heic")[0] == ("convert", "jpg")
    assert ("convert", "mp3") in suggestions("x.flac") and suggestions("x.unknown") == []
    assert drag_format("png") == "jpg" and drag_format("jpg") == "png" and drag_format("docx") == "pdf"
    assert drag_format("pdf") == "docx" and drag_format("mp4") == "gif"
    assert fits("jpg", "web") and not fits("mp4", "web") and fits("pdf", "email")
    assert savings([], []) is None and size_text(1536) == "1.5 KB"
    assert label(("convert", "jpg")) == "→ JPG" and label(("fit", "whatsapp")) == "Fit WhatsApp"
    print("notchcore self-check OK", "| battery saver:", battery_saver())
