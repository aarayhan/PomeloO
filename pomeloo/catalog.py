"""Format/tool catalog (see docs/features.md).

One table drives the wheel, the Explorer context menu and the CLI.
"""
from pathlib import Path
import re

IMAGE_IN = ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
IMAGE_OUT = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
AUDIO = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
VIDEO = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
SUBS = ["srt", "vtt"]
RICH = ["docx", "pages", "md", "rtf", "rtfd"]  # ponytail: textClipping is macOS-only, dropped
SHEETS = ["xlsx", "xls", "ods", "csv", "tsv"]
ARCHIVES = ["zip", "tar", "gz", "rar"]
RICH_OUT = ["docx", "pdf", "txt", "md", "html", "epub", "png", "jpg"]
# Input-only formats, plus "pages" which can't be written off-Mac (proprietary IWA).
NO_OUTPUT = {"rar", "ppt", "xls", "rtf", "rtfd", "pages"}

# Windows spellings -> canonical ext
ALIASES = {"jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff",
           "markdown": "md", "htm": "html", "tgz": "gz", "oga": "ogg", "m4v": "mp4"}


def ext_of(path) -> str:
    name = Path(path).name.lower()
    if name.endswith(".tar.gz"):
        return "gz"
    e = Path(name).suffix[1:]
    return ALIASES.get(e, e)


def targets(ext: str) -> list[str]:
    """Conversion targets for a source ext."""
    if ext in IMAGE_IN:
        t = IMAGE_OUT
    elif ext in AUDIO:
        t = AUDIO
    elif ext in VIDEO:
        t = VIDEO + ["gif", "mp3"]
    elif ext == "gif":
        t = VIDEO
    elif ext == "pdf":
        t = ["docx", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"]
    elif ext in ("ppt", "pptx"):
        t = ["pdf", "jpg", "png"]
    elif ext in SHEETS:
        t = SHEETS + ["pdf"]
    elif ext in RICH:
        t = RICH_OUT
    elif ext == "epub":
        t = ["pdf", "docx", "txt", "md", "html"]
    elif ext == "txt":
        t = ["docx", "pdf", "md", "html", "epub", "jpg", "png"]
    elif ext == "html":  # free via pandoc
        t = ["docx", "pdf", "txt", "md", "epub"]
    elif ext in SUBS:
        t = SUBS + ["txt"]
    elif ext in ARCHIVES:
        t = ["zip", "tar", "gz"]
    else:
        t = []
    return [x for x in t if x != ext and x not in NO_OUTPUT]


def kind(ext: str) -> str | None:
    if ext in AUDIO:
        return "audio"
    if ext in VIDEO or ext == "gif":
        return "video"
    if ext in SHEETS:
        return "spreadsheet"
    if ext in ARCHIVES:
        return "archive"
    if ext in SUBS:
        return "subtitle"
    if ext in IMAGE_IN:
        return "image"
    if ext in ["pdf", "ppt", "pptx", "txt", "html", "epub", *RICH]:
        return "document"
    return None


# id -> (wheel title, display name, output label, output ext or None=same, combines selection)
TOOLS = {
    "compress": ("COMPRESS", "Compress", "Compressed", None, False),
    "removeMetadata": ("METADATA", "Metadata", "No Metadata", None, False),
    "editImage": ("EDIT", "Edit Photo", "Edited", None, False),
    "annotateImage": ("ANNOTATE", "Annotate Photo", "Annotated", "png", False),
    "frameImage": ("ADD BG", "Add Background", "Background", None, False),
    "cropImage": ("CROP", "Crop Image", "Cropped", None, False),
    "redactImage": ("REDACT", "Redact Photo", "Redacted", None, False),
    "readQR": ("QR", "Read QR Code", None, None, False),
    "createPDF": ("CREATE PDF", "Create PDF", "PDF", "pdf", True),
    "createCollage": ("COLLAGE", "Create Collage", "Collage", "png", True),
    "normalizeAudio": ("NORMALIZE", "Normalize Volume", "Normalized", None, False),
    "audioToVideo": ("VISUALIZE", "Audio Visualizer", "Visualizer", "mp4", False),
    "trimAudio": ("TRIM", "Trim Audio", "Trimmed", None, False),
    "audioChannels": ("CHANNELS", "Convert Audio Channels", "Mono", None, False),
    "redactAudio": ("BLEEP", "Bleep Audio", "Bleeped", None, False),
    "muteVideo": ("MUTE", "Remove Audio", "Muted", None, False),
    "trimVideo": ("TRIM", "Trim Video", "Trimmed", None, False),
    "cropVideo": ("CROP", "Crop Video", "Cropped", None, False),
    "changeVideoSpeed": ("SPEED", "Change Video Speed", "Speed", None, False),
    "videoSnapshots": ("SNAPSHOT", "Video Snapshots", "Snapshot", "png", False),
    "splitVideo": ("SPLIT", "Split Video", "Clips", "folder", False),
    "redactVideo": ("REDACT", "Redact Video", "Redacted", None, False),
    "joinVideos": ("JOIN", "Join Videos", "Joined", "mp4", True),  # joined clips are always MP4
    "splitPDF": ("SPLIT", "Split PDF", "Pages", "folder", False),
    "organizePDF": ("ORGANIZE", "Organize PDF", "Organized", "pdf", False),
    "mergePDF": ("MERGE PDF", "Merge PDFs", "Merged", "pdf", True),
    "extractArchive": ("EXTRACT", "Extract Archive", "Extracted", "folder", False),
}
# Tools that still make sense with several files selected.
MULTI_OK = {"compress", "removeMetadata", "cropImage", "normalizeAudio", "muteVideo", "splitPDF",
            "extractArchive", "createPDF", "mergePDF", "joinVideos", "createCollage"}

ACTIONS = {
    "share": ("SHARE", "Share", "Share files through the Windows share sheet (AirDrop on Mac)."),
    "float": ("FLOAT", "Float", "Keep files in a floating shelf; drag them into another app."),
    "copy": ("COPY", "Copy", "Copy files to the clipboard, ready to paste in Explorer."),
    "move": ("MOVE", "Move", "Choose a destination folder and move the originals there."),
    "copyPath": ("COPY PATH", "Copy Path", "Copy full paths as text, one per line."),
    "terminal": ("TERMINAL", "Terminal", "Open the folder (or file's folder) in Windows Terminal."),
}

_PHOTO = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp"]


def tools(ext: str, n: int = 1) -> list[str]:
    """Tools for a selection of n files of this ext."""
    if n < 1:
        return []
    if ext in _PHOTO:
        t = (["compress", "removeMetadata", "cropImage", "createPDF", "createCollage"] if n > 1 else
             ["compress", "removeMetadata", "editImage", "annotateImage", "frameImage", "cropImage",
              "redactImage", "readQR"])
    elif ext == "svg":
        t = ["createPDF", "createCollage"] if n > 1 else []
    elif ext in AUDIO:
        t = ["compress", "removeMetadata", "normalizeAudio", "audioToVideo", "trimAudio",
             "audioChannels", "redactAudio"]
    elif ext in VIDEO:
        t = (["compress", "removeMetadata", "muteVideo", "trimVideo", "cropVideo",
              "changeVideoSpeed", "joinVideos"] if n > 1 else
             ["compress", "removeMetadata", "muteVideo", "trimVideo", "cropVideo",
              "changeVideoSpeed", "videoSnapshots", "splitVideo", "redactVideo"])
    elif ext == "gif":
        t = ["removeMetadata"]
    elif ext == "pdf":
        t = (["compress", "removeMetadata", "splitPDF", "mergePDF"] if n > 1 else
             ["compress", "removeMetadata", "splitPDF", "organizePDF"])
    elif ext in ARCHIVES:
        t = ["extractArchive"]
    else:
        t = []
    return [x for x in t if n == 1 or x in MULTI_OK]


def selection_ext(paths) -> str | None:
    """Common ext of a selection, or None if mixed (mixed selections only get actions)."""
    exts = {ext_of(p) for p in paths}
    if len(exts) != 1:
        # Images of different formats can still be combined (createPDF / collage).
        return "png" if exts <= set(IMAGE_IN) else None
    return exts.pop()


def stem_of(path) -> str:
    return re.sub(r"(?:\.tar\.gz|\.tgz|\.[^.]+)$", "", Path(path).name, flags=re.I)


def unique(path: Path) -> Path:
    """`x.png` -> `x 2.png` -> `x 3.png` ...."""
    if not path.exists():
        return path
    name = path.name
    base, suffix = (name[:-7], ".tar.gz") if name.endswith(".tar.gz") else (path.stem, path.suffix)
    i = 2
    while (p := path.with_name(f"{base} {i}{suffix}")).exists():
        i += 1
    return p


def out_path(src, ext: str, label: str | None = None) -> Path:
    """Output beside the source: `<stem>[ <label>].<ext>`; ext 'folder' -> directory path."""
    src = Path(src)
    name = stem_of(src) + (f" {label}" if label else "")
    if ext == "folder":
        return unique(src.parent / name)
    return unique(src.parent / f"{name}.{'tar.gz' if ext == 'gz' else ext}")


def all_input_exts() -> list[str]:
    exts = IMAGE_IN + AUDIO + VIDEO + ["gif", "pdf", "ppt", "pptx", "epub", "txt", "html"] \
        + SHEETS + RICH + SUBS + ARCHIVES
    return list(dict.fromkeys(exts))
