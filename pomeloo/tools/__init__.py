"""Tool registry: run_tool(id, paths, params) -> outputs. PARAMS drives the option dialogs."""
import inspect
from pathlib import Path

from ..catalog import TOOLS, ext_of, kind, out_path


def P(key, type_, default, label, **kw):
    return {"key": key, "type": type_, "default": default, "label": label, **kw}


def S(key, label, lo=-100, hi=100, default=0):
    return P(key, "slider", default, label, min=lo, max=hi)


PRESETS = {"high quality": 75, "balanced": 50, "smallest": 25}
_ASPECTS = ["free", "1:1", "4:5", "4:3", "3:2", "16:9", "9:16", "3:4"]
_EXACT = [P("width", "int", 0, "Exact width (0 = keep)", min=0, max=20000, suffix=" px"),
          P("height", "int", 0, "Exact height (0 = keep)", min=0, max=20000, suffix=" px")]

PARAMS = {
    "compress": [P("preset", "choice", "custom", "Preset", options=["custom", *PRESETS]),
                 P("percent", "int", 50, "Target size (% of original)", min=5, max=95, suffix=" %"),
                 P("target_kb", "int", 0, "Or exact size in KB (0 = use %)", min=0, max=10_000_000),
                 P("resize", "int", 100, "Resize images/video to", min=10, max=100, suffix=" %")],
    "removeMetadata": [P("mode", "choice", "remove", "Action", options=["remove", "edit"]),
                       P("fields", "meta", {}, "Fields")],
    "editImage": [P("_preview", "preview", None, "Preview"),
                  S("exposure", "Exposure (stops)", -3, 3, 0), S("contrast", "Contrast"),
                  S("highlights", "Highlights"), S("shadows", "Shadows"), S("saturation", "Saturation"),
                  S("temperature", "Temperature"), S("tint", "Tint"), S("clarity", "Clarity", 0),
                  S("dehaze", "Dehaze", 0), S("sharpness", "Sharpness", 0),
                  S("noise_reduction", "Noise reduction", 0), S("grain", "Grain", 0), S("vignette", "Vignette", 0),
                  P("rotate", "choice", 0, "Rotate", options=[0, 90, 180, 270]),
                  P("flip", "choice", "none", "Flip", options=["none", "horizontal", "vertical"]),
                  P("grayscale", "bool", False, "Black and white")],
    "annotateImage": [P("shapes", "shapes", [], "Draw")],
    "frameImage": [P("background", "choice", "color", "Background", options=["color", "gradient", "image", "blur"]),
                   P("color", "color", "#ffffff", "Colour"), P("color2", "color", "#ff8a00", "Gradient end"),
                   P("angle", "int", 45, "Gradient angle", min=0, max=360, suffix="°"),
                   P("image", "file", "", "Background image"),
                   P("aspect", "choice", "free", "Canvas aspect", options=["free", "1:1", "4:5", "16:9", "9:16"]),
                   P("padding", "int", 8, "Spacing", min=0, max=50, suffix=" %"),
                   P("radius", "int", 0, "Photo corner radius", min=0, max=50, suffix=" %"),
                   P("shadow", "int", 0, "Shadow", min=0, max=100, suffix=" %"),
                   P("blur", "int", 40, "Background blur", min=0, max=100, suffix=" %")],
    "cropImage": [P("rect", "rect", None, "Region"), P("aspect", "choice", "free", "Aspect", options=_ASPECTS), *_EXACT],
    "redactImage": [P("rects", "rects", [], "Regions"),
                    P("style", "choice", "pixelate", "Style", options=["pixelate", "blur", "color"]),
                    P("color", "color", "#000000", "Colour"),
                    P("auto", "choice", "none", "Also detect automatically", options=["none", "faces", "text", "both"])],
    "createPDF": [P("files", "files", None, "Page order")],
    "createCollage": [P("files", "files", None, "Order"),
                      P("layout", "choice", "grid", "Layout", options=["grid", "row", "column", "featured"]),
                      P("columns", "int", 0, "Grid columns (0 = auto)", min=0, max=12),
                      P("spacing", "int", 16, "Spacing", min=0, max=200, suffix=" px"),
                      P("radius", "int", 0, "Corner radius", min=0, max=300, suffix=" px"),
                      P("color", "color", "#ffffff", "Background"),
                      P("cell", "int", 600, "Tile size", min=100, max=3000, suffix=" px"),
                      P("width", "int", 0, "Final width (0 = natural)", min=0, max=20000, suffix=" px")],
    "normalizeAudio": [P("_loudness", "loudness", None, "Measured"),
                       P("loudness", "int", -16, "Target loudness", min=-30, max=-5, suffix=" LUFS"),
                       P("lra", "float", 11.0, "Loudness range", min=1, max=20),
                       P("true_peak", "float", -1.5, "True peak", min=-9, max=0)],
    "audioToVideo": [P("style", "choice", "waves", "Style", options=["waves", "spectrum", "image"]),
                     P("color", "color", "#ff8a00", "Wave colour"), P("image", "file", "", "Still image"),
                     P("shape", "choice", "landscape", "Video shape", options=["landscape", "portrait", "square"])],
    "trimAudio": [P("start", "range", 0.0, "Keep"), P("trim_silence", "bool", False, "Remove silence at start and end")],
    "audioChannels": [P("channels", "choice", 1, "Channels", options=[1, 2]),
                      P("left", "int", 100, "Left volume", min=0, max=200, suffix=" %"),
                      P("right", "int", 100, "Right volume", min=0, max=200, suffix=" %")],
    "redactAudio": [P("ranges", "ranges", [], "Bleep ranges"),
                    P("mode", "choice", "beep", "Mode", options=["beep", "mute"]),
                    P("frequency", "int", 1000, "Tone", min=200, max=4000, suffix=" Hz")],
    "trimVideo": [P("start", "range", 0.0, "Keep")],
    "cropVideo": [P("rect", "rect", [0, 0, 1, 1], "Region"), P("aspect", "choice", "free", "Aspect", options=_ASPECTS),
                  *_EXACT],
    "changeVideoSpeed": [P("factor", "choice", 2.0, "Speed", options=[0.25, 0.5, 0.75, 1.5, 2.0, 4.0])],
    "videoSnapshots": [P("times", "times", [], "Frames"),
                       P("count", "int", 1, "Or evenly spaced frames", min=1, max=100)],
    "splitVideo": [P("points", "times", [], "Split points"),
                   P("parts", "int", 2, "Or equal parts", min=2, max=100),
                   P("seconds", "int", 0, "Or clip length (0 = use parts)", min=0, max=86400, suffix=" s"),
                   P("precise", "bool", True, "Exact cuts (re-encode)")],
    "redactVideo": [P("rects", "rects", [], "Regions"),
                    P("style", "choice", "blur", "Style", options=["blur", "color"]),
                    P("color", "color", "#000000", "Colour"),
                    P("times", "region_times", [], "Time range per region")],
    "joinVideos": [P("files", "files", None, "Clip order")],
    "mergePDF": [P("files", "files", None, "Document order")],
    "splitPDF": [P("ranges", "text", "", "Page ranges (e.g. 1-3, 4; empty = every page)")],
    "organizePDF": [P("order", "pages", None, "Pages")],
}
_SKIP = {"preview", "loudness", "files"}  # UI-only or handled by run_tool


def defaults(tid) -> dict:
    out = {}
    for p in PARAMS.get(tid, []):
        if p["type"] == "range":
            out.update(start=0.0, end=0.0)
        elif p["type"] == "pages":
            out.update(order=None, rotations={})
        elif p["type"] not in _SKIP:
            out[p["key"]] = p["default"]
    return out


def needs_dialog(tid) -> bool:
    return bool(PARAMS.get(tid))


def _fn(tid, ext):
    from . import image, media, pdf
    k = kind(ext)
    if tid in ("compress", "removeMetadata"):
        mod = image if k == "image" else pdf if ext == "pdf" else media
        return mod.compress if tid == "compress" else mod.metadata
    return {
        "editImage": image.edit, "annotateImage": image.annotate, "frameImage": image.frame,
        "cropImage": image.crop, "redactImage": image.redact, "readQR": image.read_qr,
        "createPDF": image.create_pdf, "createCollage": image.collage,
        "normalizeAudio": media.normalize, "audioToVideo": media.visualize, "trimAudio": media.trim,
        "audioChannels": media.channels, "redactAudio": media.bleep, "muteVideo": media.mute,
        "trimVideo": media.trim, "cropVideo": media.crop, "changeVideoSpeed": media.speed,
        "videoSnapshots": media.snapshots, "splitVideo": media.split, "redactVideo": media.redact,
        "joinVideos": media.join, "splitPDF": pdf.split, "organizePDF": pdf.organize,
        "mergePDF": pdf.merge, "extractArchive": pdf.extract_archive,
    }[tid]


def _call(fn, *args, **params):
    """Pass only the params this engine function accepts (one PARAMS list serves several kinds)."""
    sig = inspect.signature(fn).parameters
    if not any(p.kind is p.VAR_KEYWORD for p in sig.values()):
        params = {k: v for k, v in params.items() if k in sig}
    return fn(*args, **params)


def read_metadata(path) -> dict:
    from . import image, media, pdf
    ext = ext_of(path)
    mod = image if kind(ext) == "image" else pdf if ext == "pdf" else media
    try:
        return mod.read_metadata(Path(path))
    except Exception:
        return {}


def run_tool(tid: str, paths, params=None) -> list:
    """Returns output Paths (or a str message for readQR)."""
    params = {**defaults(tid), **(params or {})}
    paths = [Path(p) for p in paths]
    if order := params.pop("files", None):  # reordered selection from the dialog (same files only)
        allowed = {str(p) for p in paths}
        paths = [Path(p) for p in order if str(p) in allowed] or paths
    if params.get("preset") in PRESETS:
        params["percent"] = PRESETS[params["preset"]]
    _, _, label, oext, combine = TOOLS[tid]
    if combine:
        if len(paths) < 2 and tid in ("mergePDF", "joinVideos"):
            raise ValueError("Select at least two files.")
        dst = out_path(paths[0], oext or ext_of(paths[0]), label)
        return [_call(_fn(tid, ext_of(paths[0])), paths, dst, **params)]
    out = []
    for p in paths:
        ext = ext_of(p)
        fn = _fn(tid, ext)
        if tid == "readQR":
            out.append(fn(p))
            continue
        o = "flac" if tid == "compress" and ext in ("wav", "aiff") else (oext or ext)
        lab = label
        if tid == "audioChannels":
            lab = "Mono" if int(params["channels"]) == 1 else "Stereo"
        elif tid == "changeVideoSpeed":
            lab = f"Speed {float(params['factor']):g}x"
        elif tid == "removeMetadata" and params["mode"] == "edit":
            lab = "Edited"
        out.append(_call(fn, p, out_path(p, o, lab), **params))
    return out
