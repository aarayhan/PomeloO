"""Dark-glass windows for the newer features: batch rename, history, phone transfer."""
import subprocess
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (QDialog, QHBoxLayout, QLabel, QLineEdit, QScrollArea, QSpinBox,
                               QVBoxLayout, QWidget)

from .theme import GlassMixin, button, footer, muted, section


class RenameDialog(GlassMixin, QDialog):
    """Pattern + live preview; renames in place. self.done_pairs holds what changed (for undo)."""
    SHOW = 12

    def __init__(self, paths):
        super().__init__()
        from ..rename import TOKENS
        self.paths, self.done_pairs = [Path(p) for p in paths], []
        body = self._glass("Rename", f"{len(paths)} file{'s' * (len(paths) != 1)}", self.reject)
        self.setMinimumWidth(560)
        body.addWidget(section("Pattern"))
        row = QHBoxLayout()
        self.pattern = QLineEdit("{name}")
        self.pattern.textChanged.connect(lambda: self.timer.start())
        self.start = QSpinBox(minimum=0, maximum=999999, value=1, prefix="from ")
        self.start.valueChanged.connect(lambda: self.timer.start())
        row.addWidget(self.pattern, 1)
        row.addWidget(self.start)
        body.addLayout(row)
        tokens = QHBoxLayout()
        for tok in TOKENS.split():
            tokens.addWidget(button(tok, lambda _=False, t=tok: self.pattern.insert(t)))
        tokens.addStretch()
        body.addLayout(tokens)
        body.addWidget(muted("{date} and {time} are when the photo or video was taken. {n:03} gives 001."))
        body.addWidget(section("Preview"))
        self.preview = QLabel()
        self.preview.setTextFormat(Qt.PlainText)
        self.preview.setStyleSheet("font-family: Consolas, monospace;")
        body.addWidget(self.preview)
        self.error = QLabel("")
        self.error.setStyleSheet("color:#ff6961")
        body.addWidget(self.error)
        body.addLayout(footer("Rename", self._apply, self.reject))
        self.timer = QTimer(self, singleShot=True, interval=150, timeout=self._preview)
        self._preview()

    def _plan(self):
        from ..rename import plan
        return plan(self.paths, self.pattern.text(), self.start.value())

    def _preview(self):
        pairs = self._plan()
        lines = [f"{a.name}  →  {b.name}" for a, b in pairs[:self.SHOW]]
        if len(pairs) > self.SHOW:
            lines.append(f"… and {len(pairs) - self.SHOW} more")
        self.preview.setText("\n".join(lines))
        self.adjustSize()

    def _apply(self):
        from ..rename import apply
        try:
            self.done_pairs = apply(self._plan())
        except OSError as e:
            self.error.setText(f"Could not rename: {e}")
            return
        self.accept()


class HistoryDialog(GlassMixin, QDialog):
    """Recent jobs: Show, Undo (Recycle Bin / rename back), Again (same settings)."""

    def __init__(self, again):
        super().__init__()
        self.again = again
        body = self._glass("History", "", self.reject)
        self.setMinimumSize(620, 460)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet("QScrollArea { background: transparent; border: none; }")
        self.list = QWidget()
        self.list.setStyleSheet("background: transparent;")
        self.rows = QVBoxLayout(self.list)
        self.rows.setContentsMargins(0, 0, 0, 0)
        scroll.setWidget(self.list)
        body.addWidget(scroll, 1)
        self.status = muted("")
        body.addWidget(self.status)
        self._fill()

    def _fill(self):
        from .. import history
        from .recipes import clear
        clear(self.rows)
        entries = history.load()
        if not entries:
            self.rows.addWidget(muted("Nothing yet. Converted files and tool results show up here."))
        for i, e in enumerate(entries):
            row = QWidget()
            lay = QHBoxLayout(row)
            lay.setContentsMargins(0, 2, 0, 2)
            files = e["outputs"] or [b for _, b in e["renames"]] or e["sources"]
            text = QVBoxLayout()
            text.setSpacing(0)
            text.addWidget(QLabel(e["title"]))
            names = ", ".join(Path(f).name for f in files[:3]) + (f" +{len(files) - 3}" if len(files) > 3 else "")
            text.addWidget(muted(f"{e['time']} · {names}"))
            lay.addLayout(text, 1)
            if existing := [f for f in files if Path(f).exists()]:
                lay.addWidget(button("Show", lambda _=False, f=existing[0]: subprocess.Popen(["explorer", "/select,", f])))
            if e["outputs"] or e["renames"]:
                lay.addWidget(button("Undo", lambda _=False, k=e.get("key"): self._undo(k)))
            if e["kind"] in ("convert", "tool"):
                lay.addWidget(button("Again", lambda _=False, x=e: self._again(x)))
            self.rows.addWidget(row)
        self.rows.addStretch()

    def _undo(self, key):
        from .. import history
        self.status.setText(history.undo(key))
        self._fill()

    def _again(self, e):
        sources = [s for s in e["sources"] if Path(s).exists()]
        if not sources:
            self.status.setText("The original files are gone.")
            return
        self.accept()
        self.again(e["kind"], e["id"], sources, e["params"])


class _Received(QObject):
    file = Signal(str)  # from the server thread


def qr_pixmap(text: str, size=260) -> QPixmap:
    import zxingcpp
    img = zxingcpp.write_barcode_to_image(zxingcpp.create_barcode(text, zxingcpp.BarcodeFormat.QRCode), scale=8)
    import numpy as np
    a = np.ascontiguousarray(np.asarray(img))
    q = QImage(a.data, a.shape[1], a.shape[0], a.strides[0], QImage.Format_Grayscale8).copy()
    return QPixmap.fromImage(q).scaled(size, size, Qt.KeepAspectRatio, Qt.FastTransformation)


class PhoneDialog(GlassMixin, QDialog):
    """QR code for the phone: download the shared files, or send files from the phone to this PC.
    The server stops when this window closes."""

    def __init__(self, files=()):
        super().__init__()
        from .. import phone
        self.share = None
        self.sig = _Received()
        self.sig.file.connect(self._got)
        self.share = phone.Share(files, on_receive=lambda p: self.sig.file.emit(str(p)))
        try:
            self._build(files)
        except Exception:  # never leave the server running without its window
            self.share.close()
            raise

    def _build(self, files):
        chip = f"{len(files)} file{'s' * (len(files) != 1)}" if files else "receive"
        body = self._glass("Phone", chip, self.reject)
        self.setMinimumWidth(400)
        qr = QLabel()
        qr.setPixmap(qr_pixmap(self.share.url))
        qr.setAlignment(Qt.AlignCenter)
        qr.setStyleSheet("background: white; border-radius: 14px; padding: 12px;")
        body.addWidget(qr, 0, Qt.AlignHCenter)
        body.addWidget(QLabel("Scan with your phone camera (same Wi-Fi)."))
        hint = muted(("Tap a file on the phone to download it. " if files else "")
                     + "Use “Choose files” on the phone to send files here.\n"
                     "If Windows asks about network access, allow Private networks.")
        hint.setWordWrap(True)
        body.addWidget(hint)
        link = muted(self.share.url)
        link.setTextInteractionFlags(Qt.TextSelectableByMouse)
        body.addWidget(link)
        body.addWidget(section("From the phone"))
        self.inbox = muted("Nothing yet.")
        self.inbox.setWordWrap(True)
        body.addWidget(self.inbox)
        self.got = []
        row = QHBoxLayout()
        row.addStretch()
        row.addWidget(button("Open folder", self._open_inbox))
        row.addWidget(button("Done", self.accept, primary=True))
        body.addLayout(row)

    def _got(self, path):
        self.got.append(Path(path))
        self.inbox.setText("\n".join(f"✓ {p.name}" for p in self.got[-8:]))

    def _open_inbox(self):
        from ..phone import INBOX
        INBOX.mkdir(parents=True, exist_ok=True)
        subprocess.Popen(["explorer", str(INBOX)])

    def done(self, r):
        if self.share:
            self.share.close()
            self.share = None
        super().done(r)
