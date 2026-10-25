"""Dark-glass windows: batch progress, settings, and a small message box."""
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QCursor
from PySide6.QtWidgets import (QApplication, QDialog, QFrame, QHBoxLayout, QLabel, QLineEdit, QPushButton,
                               QScrollArea, QSizeGrip, QVBoxLayout, QWidget)

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


class Batch(QObject):
    """One run (a conversion or a tool over N files): progress, results, failures, cancel. Shown by
    ProgressWindow, or by the notch's Jobs tab when the notch is on."""
    changed = Signal()
    finished = Signal()

    def __init__(self, title, jobs, sources=(), on_finish=None):
        super().__init__()
        self.title, self.sources, self.on_finish = title, [Path(s) for s in sources], on_finish
        n = len(jobs)
        self.names = [label for label, _ in jobs]
        self.fracs, self.outputs, self.failures, self.texts = [0.0] * n, [], [], []
        self.left, self.total, self.cancelled = n, n, False
        self.sig = _Signals()
        self.sig.done.connect(self._done)
        self.sig.progress.connect(self._progress)
        self.futures = [POOL.submit(_run_job, i, fn, self.sig) for i, (_, fn) in enumerate(jobs)]

    @property
    def fraction(self) -> float:
        return sum(self.fracs) / self.total if self.total else 1.0

    def status(self) -> str:
        if self.left:
            return "Cancelling…" if self.cancelled else "Working…"
        if self.cancelled:
            return "Cancelled"
        return f"Done · {len(self.failures)} failed" if self.failures else "Done"

    def savings(self) -> str | None:
        from ..notchcore import savings
        return savings(self.sources, self.outputs) if self.outputs else None

    def cancel(self):
        """Jobs not started yet are dropped; one already running finishes and its result is removed.
        Only the first call counts (Future.cancel() keeps returning True for a cancelled future)."""
        if self.cancelled or not self.left:
            return
        self.cancelled = True
        for i, f in enumerate(self.futures):
            if f.cancel():
                self._done(i, None, "cancelled")

    def _progress(self, row, f):
        self.fracs[row] = max(self.fracs[row], f)
        self.changed.emit()

    def _done(self, row, result, err):
        self.left -= 1
        self.fracs[row] = 1.0
        results = [r for r in (result if isinstance(result, list) else [result]) if r]
        if self.cancelled:  # throw away what a cancelled run still produced
            import shutil
            for r in results:
                if not isinstance(r, str) and Path(r).exists():
                    shutil.rmtree(r, ignore_errors=True) if Path(r).is_dir() else Path(r).unlink(missing_ok=True)
        elif err:
            self.failures.append(f"{self.names[row]}: {err}")
        else:
            for r in results:  # QR / OCR text is collected and copied once at the end
                (self.texts if isinstance(r, str) else self.outputs).append(r if isinstance(r, str) else Path(r))
        self.changed.emit()
        if not self.left:
            self._finish()

    def _finish(self):
        if self.on_finish and self.outputs:
            self.on_finish(self.outputs)
        if text := self.text():
            QApplication.clipboard().setText(text)
        if self.outputs:
            from ..actions import reveal
            reveal(self.outputs)  # select in an already-open Explorer window; never opens a new one
        self.finished.emit()

    def text(self) -> str:
        return "\n\n".join(t for t in self.texts if t.strip())


class ProgressWindow(QWidget):
    """Just the orange: a floating citrus slice that fills with real progress, 'Working…' then 'Done'.
    Results are selected in an already-open Explorer window. If something fails, clicking shows why.
    ProgressWindow(title, jobs, on_finish) starts a Batch; ProgressWindow(batch=b) shows an existing one."""

    def __init__(self, title=None, jobs=None, on_finish=None, batch=None):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        from .citrus import CitrusProgress
        self.batch = batch or Batch(title, jobs, on_finish=on_finish)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setToolTip(self.batch.title)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(10, 10, 10, 10)
        lay.setSpacing(8)
        self.citrus = CitrusProgress(150)
        lay.addWidget(self.citrus, 0, Qt.AlignHCenter)
        self.status = QLabel("Working…")
        self.status.setAlignment(Qt.AlignCenter)
        self.status.setStyleSheet(PILL)  # dark pill: readable on any wallpaper
        lay.addWidget(self.status, 0, Qt.AlignHCenter)
        self.batch.changed.connect(lambda: self.citrus.set_value(self.batch.fraction))
        self.batch.finished.connect(self._finished)
        self.adjustSize()
        geo = (QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()).availableGeometry()
        self.move(geo.center().x() - self.width() // 2, geo.bottom() - self.height() - 40)
        self.show()

    # kept for callers and tests that look at the window
    left = property(lambda self: self.batch.left)
    outputs = property(lambda self: self.batch.outputs)
    failures = property(lambda self: self.batch.failures)

    def _finished(self):
        b = self.batch
        self.citrus.finish()
        if text := b.text():
            preview = text if len(text) < 600 else text[:600] + "…"
            notice(self, b.title, preview + "\n\nCopied to the clipboard.", text)
        elif b.texts:
            notice(self, b.title, "No text found.")
        self.status.setText(b.status())
        if b.failures:
            self.status.setStyleSheet(PILL + " color: #ff8a80;")
            self.status.setCursor(Qt.PointingHandCursor)
            self.setToolTip("Click to see what went wrong")
        QTimer.singleShot(8000 if b.failures else 1400, lambda: self.underMouse() or self.close())

    def mousePressEvent(self, e):
        if not self.batch.left and self.batch.failures:
            notice(self, "Some files failed", "\n\n".join(self.batch.failures))
        if not self.batch.left:
            self.close()


# ---------- settings ----------
class SettingsDialog(GlassMixin, QDialog):
    """Two columns: wheel keys, shortcuts and behavior on the left; the notch on the right."""

    def __init__(self, settings: dict):
        super().__init__()
        self.setWindowTitle("PomeloO Settings")
        self.s = settings
        body = self._glass("Settings")
        # taller than many laptop screens: the columns scroll, and the corner grip resizes the frameless window
        content = QWidget(objectName="settingsBody")
        content.setStyleSheet("#settingsBody { background: transparent; }")
        self.scroll = QScrollArea(widgetResizable=True, frameShape=QFrame.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.scroll.setStyleSheet("QScrollArea { background: transparent; border: none; }")
        self.scroll.setWidget(content)
        body.addWidget(self.scroll, 1)
        cols = QHBoxLayout(content)
        cols.setContentsMargins(0, 0, 10, 0)  # room for the scrollbar
        cols.setSpacing(28)
        left, right = QVBoxLayout(), QVBoxLayout()
        cols.addLayout(left, 1)
        cols.addLayout(right, 1)
        rev = {v: k for k, v in settings["keys"].items()}
        left.addWidget(section("Wheel keys"))
        left.addWidget(muted("While dragging a file in Explorer, tap this key to open the wheel."))
        self.segs, self.toggles = {}, {}
        for mode in ("convert", "tools", "actions"):
            self.segs[mode] = self._choice(left, mode.capitalize(), ["shift", "ctrl", "alt"], rev.get(mode, "shift"),
                                           {"shift": "Shift", "ctrl": "Ctrl", "alt": "Alt"})
        left.addWidget(section("Keyboard"))
        self.hotkey = self._line(left, "Wheel hotkey", settings["hotkey"], "ctrl+shift+space")
        left.addWidget(muted("Opens the wheel for the files selected in Explorer (or what you copied)."))
        self.ocr_hotkey = self._line(left, "Copy text from screen", settings["ocr_hotkey"], "win+ctrl+t")
        left.addWidget(muted("Shortcuts apply after restarting PomeloO."))
        left.addWidget(section("Behavior"))
        self._toggles(left, (
            ("start_with_windows", "Start with Windows", "Open PomeloO automatically after you sign in."),
            ("drag_wheel", "Wheel while dragging", "Tap a key mid-drag in Explorer to open the wheel."),
            ("paste_images", "Paste images as files", "Ctrl+V in a folder saves a copied picture there."),
            ("show_pad", "Floating drop pad", "A small target in the corner to drop files on."),
            ("sound", "Highlight sound", "A soft click as you move across the wheel."),
            ("fix_whatsapp_overlay", "Fix WhatsApp desktop clicks",
             "WhatsApp leaves an invisible layer that blocks right-clicks on the desktop.")))
        left.addStretch()
        right.addWidget(section("Notch"))
        self._toggles(right, (("notch", "Show the notch",
                               "A pill at the top of the screen: shelf, drop zones, progress, phone and more."),))
        self.position = self._choice(right, "Position", ["left", "center", "right"], settings["notch_position"])
        self.screen_seg = self._choice(right, "Screen", ["primary", "cursor"], settings["notch_screen"],
                                       {"primary": "Main", "cursor": "Follow cursor"})
        self._toggles(right, (
            ("notch_progress", "Progress in the notch", "Instead of the floating orange window."),
            ("notch_downloads", "Ideas for new downloads", "A HEIC arrives: one click turns it into a JPG."),
            ("notch_screenshots", "Ideas for copied images", "Save a screenshot as a file, read its text, mark it up."),
            ("notch_clipboard", "Clipboard tab", "The last few things you copied. Never saved to disk."),
            ("notch_recent", "Recent tab", "Latest results, ready to drag out, with undo."),
            ("notch_phone", "Phone tab", "QR code to send files to and from your phone.")))
        right.addWidget(muted("The notch hides by itself during full-screen apps, games and presentations, and "
                              "never shows up in screenshots or screen sharing."))
        right.addStretch()
        self.error = QLabel("")
        self.error.setStyleSheet("color:#ff6961")
        body.addWidget(self.error)
        foot = footer("Save", self._save, self.reject)
        foot.addWidget(QSizeGrip(self), 0, Qt.AlignBottom | Qt.AlignRight)
        body.addLayout(foot)
        self.setMinimumSize(content.minimumSizeHint().width() + 60, 360)
        # open as tall as the contents, but never taller than the screen
        screen = (self.screen() or QApplication.primaryScreen()).availableGeometry()
        full = self.sizeHint().height() - self.scroll.sizeHint().height() + content.sizeHint().height()
        self.resize(self.sizeHint().width(), min(full, screen.height() - 48))

    def _choice(self, lay, label, options, value, labels=None):
        row = QHBoxLayout()
        lab = QLabel(label)
        lab.setMinimumWidth(90)
        seg = Segmented(options, value, labels or {o: o.capitalize() for o in options})
        row.addWidget(lab)
        row.addWidget(seg)
        row.addStretch()
        lay.addLayout(row)
        return seg

    def _line(self, lay, label, value, placeholder):
        row = QHBoxLayout()
        row.addWidget(QLabel(label))
        edit = QLineEdit(value)
        edit.setPlaceholderText(placeholder)
        row.addWidget(edit, 1)
        lay.addLayout(row)
        return edit

    def _toggles(self, lay, rows):
        for k, title, desc in rows:
            row = QHBoxLayout()
            text = QVBoxLayout()
            text.setSpacing(0)
            text.addWidget(QLabel(title))
            d = muted(desc)
            d.setWordWrap(True)
            text.addWidget(d)
            t = Toggle(self.s[k])
            self.toggles[k] = t
            row.addLayout(text, 1)
            row.addWidget(t)
            lay.addLayout(row)

    def _save(self):
        keys = {seg.value(): mode for mode, seg in self.segs.items()}
        if len(keys) != 3:
            self.error.setText("Each wheel needs its own key.")
            return
        self._result = {**self.s, "keys": keys, "hotkey": self.hotkey.text().strip().lower() or "ctrl+shift+space",
                        "ocr_hotkey": self.ocr_hotkey.text().strip().lower() or "win+ctrl+t",
                        "notch_position": self.position.value(), "notch_screen": self.screen_seg.value(),
                        **{k: t.isChecked() for k, t in self.toggles.items()}}
        self.accept()

    def result_settings(self) -> dict | None:
        return getattr(self, "_result", None)
