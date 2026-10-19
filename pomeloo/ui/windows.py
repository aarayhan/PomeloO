"""Dark-glass windows: batch progress, settings, and a small message box."""
import subprocess
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QFontMetrics
from PySide6.QtWidgets import (QApplication, QDialog, QHBoxLayout, QLabel, QLineEdit, QProgressBar,
                               QPushButton, QScrollArea, QVBoxLayout, QWidget)

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


class _Job(QRunnable):
    def __init__(self, row, fn, sig):
        super().__init__()
        self.row, self.fn, self.sig = row, fn, sig

    def run(self):
        try:
            self.sig.done.emit(self.row, self.fn(), "")
        except Exception as e:  # surfaced in the window, never swallowed
            self.sig.done.emit(self.row, None, str(e) or e.__class__.__name__)


class _Row(QWidget):
    """One file: name · status, with a thin bar that runs while working."""

    def __init__(self, name):
        super().__init__()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 2, 0, 2)
        lay.setSpacing(4)
        top = QHBoxLayout()
        self.name = QLabel(QFontMetrics(self.font()).elidedText(name, Qt.ElideMiddle, 300))
        self.name.setToolTip(name)
        self.status = muted("Working…")
        self.status.setWordWrap(False)
        top.addWidget(self.name, 1)
        top.addWidget(self.status)
        self.bar = QProgressBar()
        self.bar.setTextVisible(False)
        self.bar.setRange(0, 0)  # busy
        lay.addLayout(top)
        lay.addWidget(self.bar)

    def finish(self, ok: bool, text: str):
        self.bar.setRange(0, 1)
        self.bar.setValue(1)
        self.bar.setProperty("state", "done" if ok else "error")
        self.bar.style().unpolish(self.bar)
        self.bar.style().polish(self.bar)
        self.status.setText(QFontMetrics(self.font()).elidedText(text, Qt.ElideRight, 220))
        self.status.setToolTip(text)
        self.status.setStyleSheet("color:#30d158" if ok else "color:#ff6961")


class ProgressWindow(GlassMixin, QWidget):
    """Runs jobs [(label, callable)] in a thread pool; selects results in an open Explorer window."""
    pool = QThreadPool()

    def __init__(self, title, jobs):
        super().__init__(None, Qt.WindowStaysOnTopHint | Qt.Tool)
        n = len(jobs)
        body = self._glass(title, f"{n} file{'s' * (n != 1)}")
        self.setMinimumWidth(440)
        rows_box = QWidget()
        rows = QVBoxLayout(rows_box)
        rows.setContentsMargins(0, 0, 4, 0)
        rows.setSpacing(8)
        self.rows = [_Row(label) for label, _ in jobs]
        for r in self.rows:
            rows.addWidget(r)
        rows.addStretch()
        if n > 5:  # long batches scroll instead of growing off-screen
            area = QScrollArea()
            area.setWidget(rows_box)
            area.setWidgetResizable(True)
            area.setFrameShape(QScrollArea.NoFrame)
            area.setStyleSheet("QScrollArea, QScrollArea > QWidget > QWidget { background: transparent; }")
            area.setFixedHeight(5 * 52)
            body.addWidget(area)
        else:
            body.addWidget(rows_box)
        bottom = QHBoxLayout()
        self.summary = muted("")
        self.reveal = QPushButton("Show in folder")
        self.reveal.setEnabled(False)
        self.reveal.clicked.connect(self._show)
        done = QPushButton("Close")
        done.setObjectName("primary")
        done.clicked.connect(self.close)
        bottom.addWidget(self.summary, 1)
        bottom.addWidget(self.reveal)
        bottom.addWidget(done)
        body.addLayout(bottom)
        self.outputs, self.errors, self.left, self.total = [], 0, n, n
        self.sig = _Signals()
        self.sig.done.connect(self._done)
        self.pool.setMaxThreadCount(max(2, QThreadPool.globalInstance().maxThreadCount() // 2))
        self._summary()
        for i, (_, fn) in enumerate(jobs):
            self.pool.start(_Job(i, fn, self.sig))
        self.show()

    def _summary(self):
        finished = self.total - self.left
        self.summary.setText(f"{finished} of {self.total} done" + (f" · {self.errors} failed" if self.errors else ""))

    def _done(self, row, result, err):
        self.left -= 1
        if err:
            self.errors += 1
            self.rows[row].finish(False, err)
        else:
            names = []
            for r in result if isinstance(result, list) else [result]:
                if isinstance(r, str):  # e.g. QR text
                    QApplication.clipboard().setText(r)
                    notice(self, "QR code", r + "\n\nCopied to the clipboard.", r)
                    names.append("read")
                elif r:
                    self.outputs.append(Path(r))
                    names.append(Path(r).name)
            self.rows[row].finish(True, "→ " + ", ".join(names) if names else "Done")
        self._summary()
        if not self.left:
            self.reveal.setEnabled(bool(self.outputs))
            if self.outputs:
                from ..actions import reveal
                reveal(self.outputs)  # select in an already-open Explorer window; never opens a new one
            if not self.errors:
                QTimer.singleShot(1600, lambda: self.underMouse() or self.close())

    def _show(self):
        subprocess.Popen(["explorer", "/select,", str(self.outputs[0])])  # explicit click: may open a window


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
