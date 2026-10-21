"""The C helpers built from native/ by scripts/build.ps1: pomeloo-send.exe (Explorer menu) and
pomeloo_native.dll (drag gesture, Ctrl+V in folders, WhatsApp overlay fix on a native thread)."""
import ctypes
import sys
from pathlib import Path

EV_KEY, EV_UP, EV_PASTE = 1, 2, 3
KEYS = ("shift", "ctrl", "alt")
_CB = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_int)
_alive = []  # the DLL calls back forever: keep the ctypes callback from being collected


def find(name: str) -> Path | None:
    """Next to PomeloO.exe in a build, native/bin when running from source."""
    here = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).parent.parent / "native" / "bin"
    return here / name if (here / name).exists() else None


def start_watch(on_event, drag_wheel: bool, overlay_fix: bool, paste_images: bool):
    """on_event(event, key) runs on the native thread: hand it to Qt with a signal. Returns the DLL
    (for configure) or None when the helpers weren't built."""
    if not (path := find("pomeloo_native.dll")):
        return None
    dll = ctypes.CDLL(str(path))
    cb = _CB(on_event)
    _alive.append(cb)
    configure(dll, drag_wheel, overlay_fix, paste_images)
    if not dll.pomeloo_start(cb):
        return None
    import atexit
    atexit.register(dll.pomeloo_stop)  # the thread stops calling back before Python finalizes
    return dll


def configure(dll, drag_wheel: bool, overlay_fix: bool, paste_images: bool):
    if dll:
        dll.pomeloo_config(int(drag_wheel), int(overlay_fix), int(paste_images))
