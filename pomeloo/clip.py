"""Clipboard + Explorer helpers: the folder of the Explorer window in front, a copied image saved as a
file (Ctrl+V in a folder, or the clipboard used as wheel input), and the current Explorer selection."""
import ctypes
import time
from pathlib import Path

CLIP_DIR = Path.home() / "Pictures" / "PomeloO"  # where clipboard contents become files for the wheel
user32 = ctypes.windll.user32


def _explorer_window(hwnd):
    import win32com.client
    for w in win32com.client.Dispatch("Shell.Application").Windows():
        try:
            if int(w.HWND) == hwnd:
                return w
        except Exception:
            continue
    return None


def explorer_selection() -> list[str]:
    """Selected items of the foreground Explorer window (ponytail: first tab matching the HWND)."""
    try:
        if w := _explorer_window(user32.GetForegroundWindow()):
            return [it.Path for it in w.Document.SelectedItems()]
    except Exception:
        pass
    return []


def explorer_folder() -> Path | None:
    """Folder shown by the foreground Explorer window, or the Desktop when the desktop has focus."""
    hwnd = user32.GetForegroundWindow()
    buf = ctypes.create_unicode_buffer(64)
    user32.GetClassNameW(hwnd, buf, 64)
    if buf.value in ("Progman", "WorkerW"):
        from PySide6.QtCore import QStandardPaths
        return Path(QStandardPaths.writableLocation(QStandardPaths.DesktopLocation))
    try:
        if (w := _explorer_window(hwnd)) and (p := Path(w.Document.Folder.Self.Path)).is_dir():
            return p
    except Exception:
        pass
    return None


def save_image(img, folder: Path, stem: str) -> Path:
    """QImage -> '<stem> 2026-10-21 14.05.09.png' in folder (never overwrites)."""
    from .catalog import unique
    folder.mkdir(parents=True, exist_ok=True)
    dst = unique(folder / f"{stem} {time.strftime('%Y-%m-%d %H.%M.%S')}.png")
    if not img.save(str(dst), "PNG"):
        raise OSError(f"Could not write {dst}")
    return dst


def clipboard_inputs() -> list[str]:
    """What's on the clipboard as files for the wheel: copied files as they are; an image or text is
    saved into Pictures\\PomeloO first."""
    from PySide6.QtGui import QGuiApplication
    md = QGuiApplication.clipboard().mimeData()
    if md.hasUrls() and (files := [u.toLocalFile() for u in md.urls() if u.isLocalFile()]):
        return files
    if md.hasImage():
        return [str(save_image(QGuiApplication.clipboard().image(), CLIP_DIR, "Clipboard"))]
    if md.hasText() and (text := md.text().strip()):
        lines = [ln.strip().strip('"') for ln in text.splitlines() if ln.strip()]
        if all(Path(ln).exists() for ln in lines):  # copied paths
            return lines
        from .catalog import unique
        CLIP_DIR.mkdir(parents=True, exist_ok=True)
        dst = unique(CLIP_DIR / f"Clipboard {time.strftime('%Y-%m-%d %H.%M.%S')}.txt")
        dst.write_text(text, encoding="utf-8")
        return [str(dst)]
    return []
