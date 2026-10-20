"""Dark-glass windows: batch progress, settings, and a small message box."""
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QCursor
from PySide6.QtWidgets import (QApplication, QDialog, QHBoxLayout, QLabel, QLineEdit, QPushButton,
                               QVBoxLayout, QWidget)

from .theme import GlassMixin, Segmented, Toggle, footer, muted, section


# ---------- message box ----------
class Notice(GlassMixin, QDialog):
    def __init__(self, parent, title, text, copy_text=None):
        super().__init__(parent)
        self.setWindowFlag(Qt.WindowStaysOnTopHint)
        body = self._glass(title)
        lab = QLabel(text)
        lab.setWordWrap(True)
        lab.setTextInteractionFlags(Qt.TextSelectableByMouse)
        lab.setMinimumWidth(320)
        body.addWidget(lab)
        row = QHBoxLayout()
        row.addStretch()
        if copy_text:
            c = QPushButton("Copy")
            c.clicked.connect(lambda: QApplication.clipboard().setText(copy_text))
            row.addWidget(c)
        ok = QPushButton("OK")
        ok.setObjectName("primary")
        ok.clicked.connect(self.accept)
        row.addWidget(ok)
        body.addLayout(row)


def notice(parent, title, text, copy_text=None):
    Notice(parent, title, text, copy_text).exec()


# ---------- batch runner ----------
class _Signals(QObject):
    done = Signal(int, object, str)  # row, result, error
    progress = Signal(int, float)    # row, 0..1 (only engines that know their progress report it)


# Plain Python threads rather than QThreadPool + Python QRunnables that Qt deletes behind our back:
# simpler lifetimes, and crash traces show the job's real Python stack.
POOL = ThreadPoolExecutor(max_workers=max(2, (os.cpu_count() or 4) // 2), thread_name_prefix="pomeloo-job")


def _run_job(row, fn, sig):
    from ..progress import set_reporter
    last = [-1.0]

    def report(f):  # throttle: one signal per 1 %
        if f - last[0] >= 0.01 or f >= 1:
            last[0] = f
            sig.progress.emit(row, f)
    set_reporter(report)
    try:
        sig.done.emit(row, fn(), "")
    except Exception as e:  # surfaced in the window, never swallowed
        sig.done.emit(row, None, str(e) or e.__class__.__name__)
    finally:
        set_reporter(None)


PILL = ("background: rgba(24,24,27,215); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px;"
        " padding: 4px 16px; font-weight: 600;")


class ProgressWindow(QWidget):
    """Just the orange: a floating citrus slice that fills with real progress, 'Working…' then 'Done'.
    Results are selected in an already-open Explorer window. If something fails, clicking shows why."""
    def __init__(self, title, jobs):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        from .citrus import CitrusProgress
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setToolTip(title)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(10, 10, 10, 10)
        lay.setSpacing(8)
        self.citrus = CitrusProgress(150)
        lay.addWidget(self.citrus, 0, Qt.AlignHCenter)
        self.status = QLabel("Working…")
        self.status.setAlignment(Qt.AlignCenter)
        self.status.setStyleSheet(PILL)  # dark pill: readable on any wallpaper
        lay.addWidget(self.status, 0, Qt.AlignHCenter)
        n = len(jobs)
        self.names = [label for label, _ in jobs]
        self.fracs, self.outputs, self.failures, self.left, self.total = [0.0] * n, [], [], n, n
        self.sig = _Signals()
        self.sig.done.connect(self._done)
        self.sig.progress.connect(self._progress)
        self.adjustSize()
        geo = (QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()).availableGeometry()
        self.move(geo.center().x() - self.width() // 2, geo.bottom() - self.height() - 40)
        for i, (_, fn) in enumerate(jobs):
            POOL.submit(_run_job, i, fn, self.sig)
        self.show()

    def _progress(self, row, f):
        self.fracs[row] = max(self.fracs[row], f)
        self.citrus.set_value(sum(self.fracs) / self.total)

    def _done(self, row, result, err):
        self.left -= 1
        self.fracs[row] = 1.0
        if err:
            self.failures.append(f"{self.names[row]}: {err}")
        else:
            for r in result if isinstance(result, list) else [result]:
                if isinstance(r, str):  # e.g. QR text
                    QApplication.clipboard().setText(r)
                    notice(self, "QR code", r + "\n\nCopied to the clipboard.", r)
                elif r:
                    self.outputs.append(Path(r))
        self.citrus.set_value(sum(self.fracs) / self.total)
        if self.left:
            return
        self.citrus.finish()
        if self.failures:
            self.status.setText(f"Done · {len(self.failures)} failed")
            self.status.setStyleSheet(PILL + " color: #ff8a80;")
            self.status.setCursor(Qt.PointingHandCursor)
            self.setToolTip("Click to see what went wrong")
        else:
            self.status.setText("Done")
        if self.outputs:
            from ..actions import reveal
            reveal(self.outputs)  # select in an already-open Explorer window; never opens a new one
        QTimer.singleShot(8000 if self.failures else 1400, lambda: self.underMouse() or self.close())

    def mousePressEvent(self, e):
        if not self.left and self.failures:
            notice(self, "Some files failed", "\n\n".join(self.failures))
        if not self.left:
            self.close()


# ---------- settings ----------
class SettingsDialog(GlassMixin, QDialog):
    def __init__(self, settings: dict):
        super().__init__()
        self.setWindowTitle("PomeloO Settings")
        self.s = settings
        body = self._glass("Settings")
        self.setMinimumWidth(460)
        rev = {v: k for k, v in settings["keys"].items()}
        body.addWidget(section("Wheel keys"))
        body.addWidget(muted("While dragging a file in Explorer, tap this key to open the wheel."))
        self.segs = {}
        for mode in ("convert", "tools", "actions"):
            row = QHBoxLayout()
            lab = QLabel(mode.capitalize())
            lab.setMinimumWidth(90)
            seg = Segmented(["shift", "ctrl", "alt"], rev.get(mode, "shift"),
                            {"shift": "Shift", "ctrl": "Ctrl", "alt": "Alt"})
            self.segs[mode] = seg
            row.addWidget(lab)
            row.addWidget(seg)
            row.addStretch()
            body.addLayout(row)
        body.addSpacing(4)
        body.addWidget(section("Keyboard"))
        row = QHBoxLayout()
        row.addWidget(QLabel("Wheel hotkey"))
        self.hotkey = QLineEdit(settings["hotkey"])
        self.hotkey.setPlaceholderText("ctrl+shift+space")
        row.addWidget(self.hotkey, 1)
        body.addLayout(row)
        body.addWidget(muted("Opens the wheel for the files selected in Explorer. Applies after restarting PomeloO."))
        body.addSpacing(4)
        body.addWidget(section("Behavior"))
        self.toggles = {}
        for k, title, desc in (
                ("drag_wheel", "Wheel while dragging", "Tap a key mid-drag in Explorer to open the wheel."),
                ("show_pad", "Floating drop pad", "A small target in the corner to drop files on."),
                ("sound", "Highlight sound", "A soft click as you move across the wheel."),
                ("fix_whatsapp_overlay", "Fix WhatsApp desktop clicks",
                 "WhatsApp leaves an invisible layer that blocks right-clicks on the desktop.")):
            row = QHBoxLayout()
            text = QVBoxLayout()
            text.setSpacing(0)
            text.addWidget(QLabel(title))
            text.addWidget(muted(desc))
            t = Toggle(settings[k])
            self.toggles[k] = t
            row.addLayout(text, 1)
            row.addWidget(t)
            body.addLayout(row)
        self.error = QLabel("")
        self.error.setStyleSheet("color:#ff6961")
        body.addWidget(self.error)
        body.addLayout(footer("Save", self._save, self.reject))

    def _save(self):
        keys = {seg.value(): mode for mode, seg in self.segs.items()}
        if len(keys) != 3:
            self.error.setText("Each wheel needs its own key.")
            return
        self._result = {**self.s, "keys": keys, "hotkey": self.hotkey.text().strip().lower() or "ctrl+shift+space",
                        **{k: t.isChecked() for k, t in self.toggles.items()}}
        self.accept()

    def result_settings(self) -> dict | None:
        return getattr(self, "_result", None)
