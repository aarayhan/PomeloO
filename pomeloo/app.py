"""Tray app: single instance, IPC from Explorer, drag-watcher wheel, hotkey wheel, drop pad."""
import ctypes
import json
import math
import os
import struct
import sys
import threading
import time
import wave
from ctypes import wintypes
from functools import partial
from pathlib import Path

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtGui import QAction, QCursor, QIcon, QPixmap
from PySide6.QtWidgets import QApplication, QDialog, QMenu, QSystemTrayIcon

from .catalog import ACTIONS, TOOLS
from .shell import APPDIR, ICON, start_app_detached

PIPE = r"\\.\pipe\pomeloo-" + os.environ.get("USERNAME", "user")  # same name as native/send.c
SETTINGS = APPDIR / "settings.json"
TICK = APPDIR / "tick.wav"
DEFAULTS = {"keys": {"shift": "convert", "ctrl": "tools", "alt": "actions"}, "hotkey": "ctrl+shift+space",
            "drag_wheel": True, "show_pad": True, "sound": True, "fix_whatsapp_overlay": True,
            "start_with_windows": True, "recipes": [], "ocr_hotkey": "win+ctrl+t", "paste_images": True,
            "notch": True, "notch_position": "center", "notch_screen": "primary", "notch_progress": True,
            "notch_downloads": True, "notch_screenshots": True, "notch_clipboard": True, "notch_recent": True,
            "notch_phone": True}
user32 = ctypes.windll.user32


# ---------- settings / assets ----------
def load_settings() -> dict:
    try:
        return {**DEFAULTS, **json.loads(SETTINGS.read_text(encoding="utf-8"))}
    except (OSError, ValueError):
        return dict(DEFAULTS)


def save_settings(s: dict):
    APPDIR.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(s, indent=2), encoding="utf-8")


def logo(size=64) -> QPixmap:
    """The app icon: an orange slice whose segments step from transparent to solid."""
    from .ui.citrus import icon_pixmap
    return icon_pixmap(size)


def ensure_assets():
    APPDIR.mkdir(parents=True, exist_ok=True)
    try:  # rewritten each start so icon updates reach the Explorer menu too
        from .ui.citrus import write_ico
        write_ico(ICON)
    except OSError:
        pass  # file in use; the existing icon is fine
    if not TICK.exists():  # 25 ms decaying click for wheel highlights
        rate = 44100
        frames = b"".join(struct.pack("<h", int(9000 * math.exp(-i / 180) * math.sin(2 * math.pi * 1800 * i / rate)))
                          for i in range(int(rate * 0.025)))
        with wave.open(str(TICK), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(frames)


# ---------- IPC ----------
def send_or_start(kind: str, ident: str, paths) -> int:
    """`pomeloo run` (from source; builds use native/send.c): hand the request to the running app."""
    data = json.dumps({"kind": kind, "id": ident, "paths": [str(Path(p).resolve()) for p in paths]}).encode()
    for attempt in range(100):
        try:
            with open(PIPE, "wb") as f:
                f.write(data)
            return 0
        except OSError:
            if attempt == 0:
                start_app_detached()
            time.sleep(0.15)
    return 1


class Bridge(QObject):
    request = Signal(dict)
    hotkey = Signal(int)  # HOTKEY_WHEEL / HOTKEY_TEXT
    drag = Signal(int, int)  # from the native watcher thread: (event, key)
    notice = Signal(str)  # thread-safe tray messages (e.g. slide-engine download)


def serve(bridge: Bridge):
    """One JSON message per connection. The next pipe instance is created before a message is read,
    so a burst of senders (one per selected file) never finds the pipe missing. Validated in on_request."""
    import pywintypes
    import win32file
    import win32pipe

    def make():
        return win32pipe.CreateNamedPipe(PIPE, win32pipe.PIPE_ACCESS_INBOUND,
                                         win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_WAIT | 0x8,  # local only
                                         win32pipe.PIPE_UNLIMITED_INSTANCES, 0, 1 << 16, 0, None)
    h = make()
    while True:
        try:
            win32pipe.ConnectNamedPipe(h, None)
        except pywintypes.error:
            win32file.CloseHandle(h)
            h = make()
            continue
        conn, h = h, make()
        data = b""
        try:
            while len(data) < 1 << 20:
                data += win32file.ReadFile(conn, 1 << 16)[1]
        except pywintypes.error:  # sender closed its end: message complete
            pass
        finally:
            win32file.CloseHandle(conn)
        try:
            if isinstance(msg := json.loads(data), dict):
                bridge.request.emit(msg)
        except ValueError:
            pass


def _hotkey(spec: str) -> tuple[int, int]:
    mods = {"alt": 1, "ctrl": 2, "shift": 4, "win": 8}
    m, vk = 0x4000, 0  # MOD_NOREPEAT
    for part in spec.lower().split("+"):
        part = part.strip()
        if part in mods:
            m |= mods[part]
        elif part == "space":
            vk = 0x20
        elif len(part) == 1:
            vk = ord(part.upper())
        elif part.startswith("f") and part[1:].isdigit():
            vk = 0x6F + int(part[1:])
    return m, vk


HOTKEY_WHEEL, HOTKEY_TEXT = 1, 2


def hotkey_loop(specs: dict, bridge: Bridge):
    """specs {id: "ctrl+shift+space"}; WM_HOTKEY -> bridge.hotkey(id). A combo another app already
    owns (e.g. PowerToys) can't be registered: say so instead of failing silently."""
    for hid, spec in specs.items():
        m, vk = _hotkey(spec)
        if not vk or not user32.RegisterHotKey(None, hid, m, vk):
            bridge.notice.emit(f"The shortcut {spec} is used by another app. Pick another one in Settings.")
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        if msg.message == 0x0312:  # WM_HOTKEY
            bridge.hotkey.emit(int(msg.wParam))


# ---------- app ----------
class App(QObject):
    def __init__(self, qapp):
        super().__init__()
        from .ui.wheel import Wheel
        self.qapp, self.settings, self.windows = qapp, load_settings(), []
        self.pending, self.flush_timer = {}, QTimer(self, singleShot=True, interval=350, timeout=self.flush)
        self.wheel = Wheel(self.settings, self.tick)
        self.wheel.chosen.connect(lambda mode, ident, paths: self.dispatch(
            {"convert": "convert", "tools": "tool", "actions": "action"}[mode], ident, paths))
        self.bridge = Bridge()
        self.bridge.request.connect(self.on_request)
        self.bridge.hotkey.connect(self.on_hotkey)
        threading.Thread(target=serve, args=(self.bridge,), daemon=True).start()
        from . import native, shell
        self.bridge.drag.connect(self.on_drag)
        self.native = native.start_watch(self.bridge.drag.emit, self.settings["drag_wheel"],
                                         self.settings["fix_whatsapp_overlay"], self.settings["paste_images"])
        shell.set_autostart(self.settings["start_with_windows"])
        shell.compact_install()
        from .tools.detect import warm_up
        from .ui.snip import ScreenText
        self.screen_text = ScreenText()  # its overlay is ready before the first hotkey press
        QTimer.singleShot(4000, lambda: threading.Thread(target=warm_up, daemon=True).start())
        from .recipes import Watcher
        self.watch = Watcher(self._run_watched)
        self.watch.set_recipes(self.settings["recipes"])
        self._build_tray()
        if not self.native:
            self.tray.showMessage("PomeloO", "Native helpers not built (scripts/build.ps1): no wheel while dragging.")
        from .engines import libreoffice
        libreoffice.notify = self.bridge.notice.emit
        self.bridge.notice.connect(self.notify)
        threading.Thread(target=hotkey_loop, daemon=True, args=(  # after the tray: it may report a clash
            {HOTKEY_WHEEL: self.settings["hotkey"], HOTKEY_TEXT: self.settings["ocr_hotkey"]}, self.bridge)).start()
        from .ui.droppad import DropPad
        self.pad = DropPad(self)
        self.pad.setVisible(self.settings["show_pad"])
        self.notch = None
        self._set_notch()

    def tick(self):
        if self.settings["sound"]:
            import winsound
            winsound.PlaySound(str(TICK), winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)

    def _build_tray(self):
        from . import shell
        self.tray = QSystemTrayIcon(QIcon(logo(64)), self.qapp)
        self.tray.setToolTip(f"PomeloO: drag a file and tap {', '.join(self.settings['keys'])}; "
                             f"or press {self.settings['hotkey']}")
        m = self.menu = QMenu()
        pad = QAction("Show drop pad", m, checkable=True, checked=self.settings["show_pad"])
        pad.toggled.connect(lambda on: (self.pad.setVisible(on), self._set("show_pad", on)))
        m.addAction(pad)
        m.addAction("Receive from phone…", lambda: self.open_phone())
        m.addAction("Recipes…", self.open_recipes)
        m.addAction("History…", self.open_history)
        m.addAction("Settings…", self.open_settings)
        m.addSeparator()
        m.addAction("Add to Explorer menu", lambda: self.tray.showMessage(
            "PomeloO", f"Registered {shell.register(self.settings['recipes'])} keys."))
        m.addAction("Remove from Explorer menu", lambda: self.tray.showMessage("PomeloO", f"Removed {shell.unregister()} keys."))
        m.addSeparator()
        m.addAction("Quit", self.qapp.quit)
        self.tray.setContextMenu(m)
        self.tray.show()

    def _set(self, k, v):
        self.settings[k] = v
        save_settings(self.settings)

    def open_settings(self):
        from .ui.windows import SettingsDialog
        d = SettingsDialog(self.settings)
        if d.exec() == QDialog.Accepted and (s := d.result_settings()):
            self.settings.update(s)
            save_settings(self.settings)
            self.pad.setVisible(s["show_pad"])
            from . import native, shell
            native.configure(self.native, s["drag_wheel"], s["fix_whatsapp_overlay"], s["paste_images"])
            shell.set_autostart(s["start_with_windows"])
            self._set_notch()
            self.notify("Saved. A new shortcut applies after restarting PomeloO.")

    def _set_notch(self):
        """Create, update or hide the notch to match the settings."""
        from . import native
        on = self.settings["notch"]
        native.notch(self.native, on)
        if on and self.notch is None:
            from .ui.notch import Notch
            self.notch = Notch(self)
        elif self.notch is not None:
            self.notch.apply_settings()
            self.notch.setVisible(on and not self.notch.quiet)

    def _notch_on(self) -> bool:
        return self.notch is not None and self.settings["notch"]

    def notify(self, message: str):
        if not (self._notch_on() and self.notch.isVisible() and self.notch.toast(message, 5000)):
            self.tray.showMessage("PomeloO", message)

    def reveal_new(self, path):
        from .actions import select_in_explorer
        select_in_explorer(path)

    def on_drag(self, event: int, key: int):
        """Drag gesture from the native watcher: a modifier tapped mid-drag opens that wheel under the
        cursor (it becomes the drop target); releasing the button closes a wheel nobody dropped on."""
        from .native import EV_DRAG_TOP, EV_KEY, EV_PASTE, EV_QUIET, KEYS
        wheel = self.wheel
        if event == EV_PASTE:
            return self.paste_image()
        if event in (EV_DRAG_TOP, EV_QUIET):
            if self._notch_on():
                self.notch.open_drop() if event == EV_DRAG_TOP else self.notch.set_quiet(bool(key))
            return
        if event == EV_KEY:
            if (mode := self.settings["keys"].get(KEYS[key])) and not wheel.isVisible():
                wheel.open_drag(QCursor.pos(), mode)
        elif wheel.isVisible() and not wheel.keyboard:
            QTimer.singleShot(400, lambda: wheel.keyboard or wheel.close_wheel())

    # requests from Explorer arrive one process per selected file: batch them
    def on_request(self, msg: dict):
        kind, ident = msg.get("kind"), msg.get("id")
        allowed = {"tool": TOOLS, "action": ACTIONS}
        if kind == "convert":
            if not (isinstance(ident, str) and ident.isalnum()):
                return
        elif kind == "tool" and isinstance(ident, str) and self._recipe(ident):
            pass
        elif kind not in allowed or ident not in allowed[kind]:
            return
        paths = [p for p in msg.get("paths", []) if isinstance(p, str) and Path(p).exists()]
        self.pending.setdefault((kind, ident), []).extend(paths)
        self.flush_timer.start()

    def flush(self):
        pending, self.pending = self.pending, {}
        for (kind, ident), paths in pending.items():
            self.dispatch(kind, ident, list(dict.fromkeys(paths)))

    def on_hotkey(self, which: int):
        """Wheel hotkey: the Explorer selection, else whatever is on the clipboard (files, an image,
        text). Text hotkey: drag over the screen and the text lands on the clipboard."""
        from .clip import clipboard_inputs, explorer_selection
        if which == HOTKEY_TEXT:
            return self.screen_text.trigger()
        if not (paths := explorer_selection() or clipboard_inputs()):
            self.tray.showMessage("PomeloO", "Select files in Explorer (or copy something), then press the hotkey.")
            return
        self.wheel.open_keyboard(QCursor.pos(), paths, "convert")
        user32.SetForegroundWindow(int(self.wheel.winId()))

    def paste_image(self):
        """Ctrl+V in an Explorer folder / on the desktop while the clipboard holds an image (and no
        files): save it there as a PNG and select it."""
        from .actions import reveal
        from .clip import explorer_folder, save_image
        md = self.qapp.clipboard().mimeData()
        if not md.hasImage() or md.hasUrls() or not (folder := explorer_folder()):
            return
        try:
            out = save_image(self.qapp.clipboard().image(), folder, "Pasted image")
        except OSError as e:
            return self.screen_text.toast.show_text(str(e))
        reveal([out])
        self.screen_text.toast.show_text(f"Saved {out.name}")

    def dispatch(self, kind: str, ident: str, paths: list, params=None):
        """params given (History > Again) skips the options dialog."""
        if not paths:
            return
        from . import history
        from .ui.dialogs import ParamDialog
        from .ui.windows import notice
        try:
            if kind == "action" and ident == "rename":
                from .ui.extras import RenameDialog
                dlg = RenameDialog(paths)
                if dlg.exec() == QDialog.Accepted and dlg.done_pairs:
                    history.add(f"Rename {len(dlg.done_pairs)} files", kind, ident, paths, renames=dlg.done_pairs)
                return
            if kind == "action" and ident == "phone":
                return self.open_phone(paths)
            if kind == "action" and ident == "float" and self._notch_on():
                return self.notch.add_to_shelf(paths)
            if kind == "action":
                from .actions import run_action
                run_action(ident, paths)
                return
            if kind == "convert":
                from .engines import convert
                jobs = [(Path(p).name, partial(convert, p, ident)) for p in paths]
                title = f"Convert to {ident.upper()}"
            elif recipe := self._recipe(ident):
                from . import recipes
                jobs = [(Path(p).name, partial(recipes.run, recipe, p)) for p in paths]
                title = "★ " + recipe["name"]
            else:
                from .tools import PARAMS, run_tool
                if params is None and PARAMS.get(ident):
                    dlg = ParamDialog(ident, paths)
                    dlg.raise_()
                    if dlg.exec() != QDialog.Accepted:
                        return
                    params = dlg.values()
                title = TOOLS[ident][1]
                if TOOLS[ident][4]:  # combines the whole selection
                    jobs = [(f"{len(paths)} files", partial(run_tool, ident, paths, params))]
                else:
                    jobs = [(Path(p).name, partial(run_tool, ident, [p], params)) for p in paths]
            self.start_batch(title, jobs, paths, partial(history.add, title, kind, ident, paths, params=params))
        except Exception as e:
            notice(None, "Something went wrong", str(e))

    def _recipe(self, ident: str) -> dict | None:
        from .recipes import PREFIX
        name = ident[len(PREFIX):] if ident.startswith(PREFIX) else None
        return next((r for r in self.settings.get("recipes", []) if r["name"] == name), None)

    def _run_watched(self, recipe, path, out_dir):
        """A new file in a recipe's watch folder (see recipes.Watcher)."""
        from . import history, recipes
        title = "★ " + recipe["name"]
        self.start_batch(title, [(path.name, partial(recipes.run, recipe, path, out_dir))], [path],
                         partial(history.add, title, "tool", "recipe:" + recipe["name"], [path]))

    def start_batch(self, title, jobs, sources, record=None):
        """Run jobs; progress shows in the notch (when on) or the citrus window. record(outputs=...)
        writes the History entry when it finishes."""
        from .ui.windows import Batch, ProgressWindow
        b = Batch(title, jobs, sources, on_finish=(lambda outs: record(outputs=outs)) if record else None)
        in_notch = self._notch_on() and self.settings["notch_progress"] and self.notch.isVisible()
        if self.notch is not None:
            self.notch.track(b, in_notch)
        if not in_notch:
            self.windows = [w for w in self.windows if w.isVisible()] + [ProgressWindow(batch=b)]
        return b

    def run_fit(self, preset, paths):
        """Notch zones "Fit WhatsApp / Email / Web": a smaller copy for that destination."""
        from . import history, notchcore
        title = f"Fit {notchcore.FIT[preset]}"
        self.start_batch(title, [(Path(p).name, partial(notchcore.fit, p, preset)) for p in paths], paths,
                         partial(history.add, title, "fit", preset, paths))

    def open_recipes(self):
        from . import shell
        from .ui.recipes import RecipesDialog
        d = RecipesDialog(self.settings["recipes"])
        if d.exec() == QDialog.Accepted:
            self._set("recipes", d.result_recipes())
            self.watch.set_recipes(self.settings["recipes"])
            if shell.is_registered():  # keep the right-click menu's ★ entries in sync
                shell.register(self.settings["recipes"])

    def open_history(self):
        from .ui.extras import HistoryDialog
        HistoryDialog(self.dispatch).exec()

    def open_phone(self, paths=()):
        """QR transfer: send `paths` to the phone, or (from the tray, no paths) receive from it."""
        if self._notch_on() and self.settings["notch_phone"]:
            return self.notch.open_phone(paths)
        from .ui.extras import PhoneDialog
        from .ui.windows import notice
        try:
            dlg = PhoneDialog(paths)
        except (RuntimeError, OSError) as e:
            return notice(None, "Phone", str(e))
        dlg.exec()


def main() -> int:
    mutex = ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\PomeloOApp")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        return 0
    qapp = QApplication(sys.argv)
    qapp.setQuitOnLastWindowClosed(False)
    qapp.setApplicationName("PomeloO")
    from .ui.theme import QSS
    qapp.setStyleSheet(QSS)
    ensure_assets()
    qapp.setWindowIcon(QIcon(str(ICON)))
    app = App(qapp)  # noqa: F841 (keep alive)
    rc = qapp.exec()
    del mutex
    return rc
