"""convert(src, target) -> output path beside src. Engines import lazily (fast CLI start)."""
from pathlib import Path

from ..catalog import ext_of, kind, out_path, targets


def convert(src, target: str) -> Path:
    src = Path(src)
    ext = ext_of(src)
    if target not in targets(ext):
        raise ValueError(f"Can't convert .{ext} to {target}")
    dst = out_path(src, target)
    k = kind(ext)
    if k == "image":
        from . import image
        image.convert(src, dst, target)
    elif k in ("audio", "video"):
        from . import media
        media.convert(src, dst, target)
    elif k == "subtitle":
        from . import misc
        misc.subtitle_convert(src, dst, target)
    elif k == "archive":
        from . import misc
        misc.archive_convert(src, dst, target)
    else:
        from . import docs
        return docs.convert(src, dst, ext, target)
    return dst
