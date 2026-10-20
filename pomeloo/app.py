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
from multiprocessing.connection import Client, Listener
from pathlib import Path

from PySide6.QtCore import QObject, QPoint, QPointF, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QCursor, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication, QDialog, QMenu, QSystemTrayIcon, QWidget

from .catalog import ACTIONS, TOOLS
from .shell import APPDIR, ICON, start_app_detached

PIPE = r"\\.\pipe\pomeloo-" + os.environ.get("USERNAME", "user")
AUTH = b"pomeloo-local-ipc"
SETTINGS = APPDIR / "settings.json"
TICK = APPDIR / "tick.wav"
DEFAULTS = {"keys": {"shift": "convert", "ctrl": "tools", "alt": "actions"}, "hotkey": "ctrl+shift+space",
            "drag_wheel": True, "show_pad": True, "sound": True, "fix_whatsapp_overlay": True}
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
    """Called by Explorer verbs: hand the request to the running app, starting it if needed."""
    msg = {"kind": kind, "id": ident, "paths": [str(Path(p).resolve()) for p in paths]}
    for attempt in range(100):
        try:
            c = Client(PIPE, family="AF_PIPE", authkey=AUTH)
            c.send(msg)
            c.close()
            return 0
        except OSError:
            if attempt == 0:
                start_app_detached()
            time.sleep(0.15)
    return 1


class Bridge(QObject):
    request = Signal(dict)
    hotkey = Signal()
    notice = Signal(str)  # thread-safe tray messages (e.g. slide-engine download)


def serve(bridge: Bridge):
    with Listener(PIPE, family="AF_PIPE", authkey=AUTH) as listener:
        while True:
            try:
                with listener.accept() as conn:
                    bridge.request.emit(conn.recv())
            except Exception:
                continue  # bad client / auth failure: ignore, keep serving


def hotkey_loop(spec: str, bridge: Bridge):
    mods = {"alt": 1, "ctrl": 2, "shift": 4, "win": 8}
    m, vk = 0x4000, 0  # MOD_NOREPEAT
    for part in spec.split("+"):
        part = part.strip()
        if part in mods:
            m |= mods[part]
        elif part == "space":
            vk = 0x20
        elif len(part) == 1:
            vk = ord(part.upper())
        elif part.startswith("f") and part[1:].isdigit():
            vk = 0x6F + int(part[1:])
    if not vk or not user32.RegisterHotKey(None, 1, m, vk):
        return
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        if msg.message == 0x0312:  # WM_HOTKEY
            bridge.hotkey.emit()


# ---------- Explorer helpers ----------
def _class(hwnd) -> str:
    buf = ctypes.create_unicode_buffer(64)
    user32.GetClassNameW(hwnd, buf, 64)
    return buf.value


def foreground_is_file_source() -> bool:
    hwnd = user32.GetForegroundWindow()
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value == os.getpid() or _class(hwnd) in ("CabinetWClass", "ExploreWClass", "Progman", "WorkerW")


def explorer_selection() -> list[str]:
    """Selected items of the foreground Explorer window (ponytail: first tab matching the HWND)."""
    hwnd = user32.GetForegroundWindow()
    try:
        import win32com.client
        for w in win32com.client.Dispatch("Shell.Application").Windows():
            try:
                if int(w.HWND) == hwnd:
                    return [it.Path for it in w.Document.SelectedItems()]
            except Exception:
                continue
    except Exception:
        pass
    return []


def fix_invisible_overlays():
    """WhatsApp Desktop leaves a full-screen WebView2 window at opacity 0 above the desktop, which
    swallows clicks on the wallpaper (and drags). Make such fully invisible windows click-through.
    Only windows that are 100% transparent are touched, so nothing visible changes behaviour."""
    import win32gui
    screen = user32.GetSystemMetrics(0) * user32.GetSystemMetrics(1)

    def check(h, _):
        if (not win32gui.IsWindowVisible(h) or win32gui.GetClassName(h) != "Chrome_WidgetWin_1"
                or not win32gui.GetWindowText(h).endswith("WhatsApp")):
            return
        ex = win32gui.GetWindowLong(h, -20)  # GWL_EXSTYLE
        if not ex & 0x80000 or ex & 0x20:  # needs WS_EX_LAYERED, not yet WS_EX_TRANSPARENT
            return
        try:
            _, alpha, flags = win32gui.GetLayeredWindowAttributes(h)
        except Exception:
            return
        l, t, r, b = win32gui.GetWindowRect(h)
        if flags & 2 and alpha == 0 and (r - l) * (b - t) >= screen / 2:  # LWA_ALPHA, fully invisible
            win32gui.SetWindowLong(h, -20, ex | 0x20)
    try:
        win32gui.EnumWindows(check, None)
    except Exception:
        pass  # windows can vanish mid-enumeration


class DragWatcher(QObject):
    """Drag gesture: while dragging files in Explorer, tap Shift/Ctrl/Alt -> wheel at cursor.
    The wheel window appears under the cursor and becomes the drop target of the ongoing drag."""
    VK = {"shift": 0x10, "ctrl": 0x11, "alt": 0x12}

    def __init__(self, app):
        super().__init__()
        self.app, self.lb, self.armed, self.start, self.prev = app, False, False, QPoint(), {}
        self.timer = QTimer(self, interval=25, timeout=self.tick)
        self.timer.start()

    def _keys(self):
        return {k: bool(user32.GetAsyncKeyState(v) & 0x8000) for k, v in self.VK.items()}

    def tick(self):
        if not self.app.settings["drag_wheel"]:
            return
        lb, wheel = bool(user32.GetAsyncKeyState(0x01) & 0x8000), self.app.wheel
        pos = QCursor.pos()
        if lb and not self.lb:
            self.start, self.armed, self.prev = pos, foreground_is_file_source(), self._keys()
        elif lb and self.armed and not wheel.isVisible() and (pos - self.start).manhattanLength() > 12:
            now = self._keys()
            newly = [k for k in now if now[k] and not self.prev.get(k)]
            if len(newly) == 1 and sum(now.values()) == 1 and (mode := self.app.settings["keys"].get(newly[0])):
                wheel.open_drag(pos, mode)
            self.prev = now
        elif not lb and self.lb and wheel.isVisible() and not wheel.keyboard:
            QTimer.singleShot(400, lambda: wheel.keyboard or wheel.close_wheel())
        self.lb = lb


class DropPad(QWidget):
    """Small always-on-top target: drop files on it to open the wheel (no key tapping needed)."""

    def __init__(self, app):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.app, self._grab = app, None
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAcceptDrops(True)
        self.setFixedSize(68, 68)
        self.setToolTip("PomeloO: drop files here. Right-click for the menu.")
        self.hot, self.fruit = False, logo(40)
        geo = QApplication.primaryScreen().availableGeometry()
        self.move(geo.right() - 88, geo.bottom() - 98)

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        c = QPointF(34, 34)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(0, 0, 0, 70))  # soft shadow
        g.drawEllipse(c + QPointF(0, 2), 29, 29)
        if self.hot:  # glow ring when hovered or a file is over it
            g.setBrush(QColor(255, 138, 0, 90))
            g.drawEllipse(c, 33, 33)
        g.setBrush(QColor(28, 28, 31, 230))
        g.setPen(QPen(QColor(255, 255, 255, 40), 1))
        g.drawEllipse(c, 28, 28)
        g.drawPixmap(14, 15, self.fruit)
        g.end()

    def enterEvent(self, e):
        self.hot = True
        self.update()

    def leaveEvent(self, e):
        self.hot = False
        self.update()

    def dragLeaveEvent(self, e):
        self.leaveEvent(e)

    def dragEnterEvent(self, e):
        self.enterEvent(e)
        if e.mimeData().hasUrls():
            e.acceptProposedAction()
            mode = self.app.wheel.mode_for_modifiers(e.modifiers()) or "convert"
            self.app.wheel.open_drag(self.mapToGlobal(self.rect().center()), mode)

    def mousePressEvent(self, e):
        if e.button() == Qt.RightButton:
            self.app.menu.popup(e.globalPosition().toPoint())
        else:
            self._grab = e.globalPosition().toPoint() - self.pos()

    def mouseMoveEvent(self, e):
        if self._grab is not None:
            self.move(e.globalPosition().toPoint() - self._grab)

    def mouseReleaseEvent(self, e):
        self._grab = None


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
        threading.Thread(target=hotkey_loop, args=(self.settings["hotkey"], self.bridge), daemon=True).start()
        self.watcher = DragWatcher(self)
        self.overlay_fix = QTimer(self, interval=2000, timeout=lambda: self.settings.get(
            "fix_whatsapp_overlay", True) and fix_invisible_overlays())
        self.overlay_fix.start()
        self._build_tray()
        from .engines import libreoffice
        libreoffice.notify = self.bridge.notice.emit
        self.bridge.notice.connect(lambda m: self.tray.showMessage("PomeloO", m))
        self.pad = DropPad(self)
        self.pad.setVisible(self.settings["show_pad"])

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
        m.addAction("Settings…", self.open_settings)
        m.addSeparator()
        m.addAction("Add to Explorer menu", lambda: self.tray.showMessage("PomeloO", f"Registered {shell.register()} keys."))
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
            self.tray.showMessage("PomeloO", "Saved. A new hotkey applies after restarting PomeloO.")

    # requests from Explorer arrive one process per selected file: batch them
    def on_request(self, msg: dict):
        kind, ident = msg.get("kind"), msg.get("id")
        allowed = {"tool": TOOLS, "action": ACTIONS}
        if kind == "convert":
            if not (isinstance(ident, str) and ident.isalnum()):
                return
        elif kind not in allowed or ident not in allowed[kind]:
            return
        paths = [p for p in msg.get("paths", []) if isinstance(p, str) and Path(p).exists()]
        self.pending.setdefault((kind, ident), []).extend(paths)
        self.flush_timer.start()

    def flush(self):
        pending, self.pending = self.pending, {}
        for (kind, ident), paths in pending.items():
            self.dispatch(kind, ident, list(dict.fromkeys(paths)))

    def on_hotkey(self):
        paths = explorer_selection()
        if not paths:
            self.tray.showMessage("PomeloO", "Select files in an Explorer window, then press the hotkey.")
            return
        self.wheel.open_keyboard(QCursor.pos(), paths, "convert")
        user32.SetForegroundWindow(int(self.wheel.winId()))

    def dispatch(self, kind: str, ident: str, paths: list):
        if not paths:
            return
        from .ui.dialogs import ParamDialog
        from .ui.windows import ProgressWindow, notice
        try:
            if kind == "action":
                from .actions import run_action
                run_action(ident, paths)
                return
            if kind == "convert":
                from .engines import convert
                jobs = [(Path(p).name, partial(convert, p, ident)) for p in paths]
                title = f"Convert to {ident.upper()}"
            else:
                from .tools import PARAMS, run_tool
                params = None
                if PARAMS.get(ident):
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
            self.windows = [w for w in self.windows if w.isVisible()] + [ProgressWindow(title, jobs)]
        except Exception as e:
            notice(None, "Something went wrong", str(e))


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
