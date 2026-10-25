"""What the open notch shows: Jobs (queue), Shelf, Clipboard, Recent, Phone. See ui/notch.py."""
import hashlib
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PySide6.QtCore import QEvent, QFileInfo, QMimeData, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QCursor, QDrag, QGuiApplication, QImage, QPixmap
from PySide6.QtWidgets import (QApplication, QFileIconProvider, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QMenu, QProgressBar, QToolTip, QVBoxLayout, QWidget)

from .theme import button, muted

_ICONS = None
_TIPS: dict = {}  # path|mtime -> tooltip html (thumbnail + info)
_TIP_POOL = ThreadPoolExecutor(1, thread_name_prefix="pomeloo-preview")  # previews never block the UI
THUMBS = Path(tempfile.gettempdir()) / "pomeloo-thumbs"
DRAGS = Path(tempfile.gettempdir()) / "pomeloo-drag"
DRAG_LIMIT = 40 * 1024 * 1024  # bigger files aren't converted mid-drag (it would freeze the UI)


def _prune(folder: Path, days: float):
    """Remove leftovers (thumbnails, Shift-drag copies) older than `days`."""
    cutoff = time.time() - days * 86400
    for p in folder.glob("*") if folder.exists() else []:
        try:
            if p.stat().st_mtime < cutoff:
                shutil.rmtree(p, ignore_errors=True) if p.is_dir() else p.unlink()
        except OSError:
            pass


def file_icon(path):
    global _ICONS
    _ICONS = _ICONS or QFileIconProvider()
    return _ICONS.icon(QFileInfo(str(path)))


def file_mime(paths) -> QMimeData:
    md = QMimeData()
    md.setUrls([QUrl.fromLocalFile(str(p)) for p in paths])
    return md


def preview_tip(path) -> str:
    """Hover preview: a thumbnail (photo, video frame, first PDF page) and one line of info. Built in
    the background on the first hover (shown from the next one), cached after that."""
    p = Path(path)
    key = f"{p}|{p.stat().st_mtime_ns if p.exists() else 0}"
    if key not in _TIPS:
        _TIPS[key] = f"<b>{p.name}</b><br>Preparing preview…"
        _TIP_POOL.submit(_build_tip, p, key)
    return _TIPS[key]


def _build_tip(p: Path, key: str):
    from ..catalog import ext_of, kind
    from ..notchcore import info
    img = ""
    try:
        THUMBS.mkdir(exist_ok=True)
        thumb = THUMBS / f"{hashlib.md5(key.encode()).hexdigest()}.png"
        if kind(ext_of(p)) in ("image", "video"):
            from .dialogs import preview_image
            im = preview_image(p)
        elif ext_of(p) == "pdf":
            import pymupdf as fitz
            from PIL import Image
            with fitz.open(p) as doc:
                pix = doc[0].get_pixmap(dpi=40)
                im = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
        else:
            im = None
        if im is not None:
            im = im.convert("RGB")
            im.thumbnail((200, 140))
            im.save(thumb)
            img = f'<img src="{QUrl.fromLocalFile(str(thumb)).toString()}"><br>'
    except Exception:
        pass
    _TIPS[key] = f"{img}<b>{p.name}</b><br>{info(p)}"


class FileList(QListWidget):
    """Icon list you can drag files out of (to Explorer, chat apps, mail...). Shift while dragging drops
    the file converted to the usual next format (PNG→JPG, DOCX→PDF...), via notchcore.drag_format."""
    dropped = Signal(list)

    def __init__(self, accept_drops=False):
        super().__init__(viewMode=QListWidget.IconMode)
        self.setIconSize(QSize(36, 36))
        self.setGridSize(QSize(92, 74))
        self.setWordWrap(True)
        self.setMovement(QListWidget.Static)
        self.setFlow(QListWidget.LeftToRight)
        self.setWrapping(True)
        self.setResizeMode(QListWidget.Adjust)  # re-flow when the notch opens wide
        self.setSelectionMode(QListWidget.ExtendedSelection)
        self.setDragEnabled(True)
        self.setAcceptDrops(accept_drops)
        self.setStyleSheet("QListWidget{background:transparent;border:none;color:#e4e4e7;font-size:11px}")

    def paths(self, selected=False):
        items = self.selectedItems() if selected else [self.item(i) for i in range(self.count())]
        return [i.data(Qt.UserRole) for i in items]

    def set_paths(self, paths):
        self.clear()
        for p in paths:
            it = QListWidgetItem(file_icon(p), Path(p).name)
            it.setData(Qt.UserRole, str(p))
            self.addItem(it)

    def viewportEvent(self, e):
        if e.type() == QEvent.ToolTip and (it := self.itemAt(e.pos())):
            QToolTip.showText(e.globalPos(), preview_tip(it.data(Qt.UserRole)), self)
            return True
        return super().viewportEvent(e)

    def startDrag(self, actions):
        paths = self.paths(selected=True)
        if not paths:
            return
        if QGuiApplication.keyboardModifiers() & Qt.ShiftModifier:
            paths = self._converted(paths)
        d = QDrag(self)
        d.setMimeData(file_mime(paths))
        d.setPixmap(file_icon(paths[0]).pixmap(48, 48))
        d.exec(Qt.CopyAction | Qt.MoveAction, Qt.CopyAction)

    def _converted(self, paths):
        """Shift-drag: convert copies in a temp folder (the originals stay as they are)."""
        from ..catalog import ext_of
        from ..engines import convert
        from ..notchcore import drag_format
        _prune(DRAGS, 1)  # yesterday's drags have long been delivered
        DRAGS.mkdir(exist_ok=True)
        out, tmp, skipped = [], Path(tempfile.mkdtemp(dir=DRAGS)), False
        QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            for p in paths:
                fmt = drag_format(ext_of(p)) if Path(p).is_file() else None
                if fmt and Path(p).stat().st_size > DRAG_LIMIT:
                    fmt, skipped = None, True
                out.append(str(convert(shutil.copy2(p, tmp / Path(p).name), fmt)) if fmt else p)
        except Exception:
            out = paths  # converting failed: drop the originals rather than nothing
        finally:
            QApplication.restoreOverrideCursor()
        if skipped:
            QToolTip.showText(QCursor.pos(), "Big files are dropped as they are: convert them first.")
        return out

    def dragEnterEvent(self, e):
        if self.acceptDrops() and e.mimeData().hasUrls() and e.source() is not self:
            e.acceptProposedAction()

    dragMoveEvent = dragEnterEvent

    def dropEvent(self, e):
        self.dropped.emit([u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()])
        e.acceptProposedAction()


def _clear_rows(layout, keep_last: int):
    """Remove widgets from the top of a layout until only `keep_last` items remain."""
    while layout.count() > keep_last:
        if w := layout.takeAt(0).widget():
            w.setParent(None)
            w.deleteLater()


def _select(paths):
    from ..actions import select_in_explorer
    if paths:
        select_in_explorer(paths[0])


# ---------- Jobs ----------
class JobsTab(QWidget):
    """Running and recent batches: progress, cancel, size saved, show the results."""
    KEEP = 5

    def __init__(self):
        super().__init__()
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(0, 0, 0, 0)
        self.rows = []  # (row widget, batch), newest first
        self.empty = muted("Nothing running. Conversions and tools show their progress here.")
        self.lay.addWidget(self.empty)
        self.lay.addStretch()

    def add(self, batch):
        row = QWidget()
        g = QVBoxLayout(row)
        g.setContentsMargins(0, 2, 0, 2)
        g.setSpacing(2)
        top = QHBoxLayout()
        status = muted("Working…")
        bar = QProgressBar(maximum=1000, textVisible=False)
        bar.setFixedHeight(4)
        cancel = button("Cancel", batch.cancel)
        show = button("Show", lambda: _select(batch.outputs))
        show.hide()
        top.addWidget(QLabel(batch.title), 1)
        top.addWidget(status)
        top.addWidget(cancel)
        top.addWidget(show)
        g.addLayout(top)
        g.addWidget(bar)

        def update():
            bar.setValue(int(batch.fraction * 1000))
            status.setText(batch.status() if batch.left else " · ".join(
                x for x in (batch.status(), batch.savings()) if x))

        def finished():
            update()
            cancel.hide()
            show.setVisible(bool(batch.outputs))
            if batch.failures:
                status.setStyleSheet("color:#ff8a80")
                status.setToolTip("\n".join(batch.failures))
        batch.changed.connect(update)
        batch.finished.connect(finished)
        self.empty.hide()
        self.lay.insertWidget(0, row)
        self.rows.insert(0, (row, batch))
        while len(self.rows) > self.KEEP:  # trim the oldest *finished* rows; running ones always stay
            done = [(w, b) for w, b in self.rows if not b.left]
            if not done:
                break
            w, b = done[-1]
            self.rows.remove((w, b))
            self.lay.removeWidget(w)
            w.setParent(None)
            w.deleteLater()

    @property
    def batches(self):
        return [b for _, b in self.rows]

    def running(self) -> bool:
        return any(b.left for b in self.batches)


# ---------- Shelf ----------
class ShelfTab(QWidget):
    """Files parked in the notch (Float). Kept across restarts."""
    changed = Signal()

    def __init__(self):
        super().__init__()
        from ..notchcore import load_shelf
        _prune(THUMBS, 7)  # once per start: old hover thumbnails
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.list = FileList(accept_drops=True)
        self.list.dropped.connect(self.add)
        self.list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._menu)
        lay.addWidget(self.list, 1)
        foot = QHBoxLayout()
        foot.addWidget(muted("Drop files here to keep them handy · drag them out anywhere · Shift+drag converts"), 1)
        foot.addWidget(button("Clear", self.clear))
        lay.addLayout(foot)
        self.list.set_paths(load_shelf())

    def add(self, paths):
        have = set(self.list.paths())
        self._set(self.list.paths() + [str(p) for p in paths if str(p) not in have])

    def remove(self, paths):
        gone = set(paths)
        self._set([p for p in self.list.paths() if p not in gone])

    def clear(self):
        self._set([])

    def _set(self, paths):
        from ..notchcore import save_shelf
        self.list.set_paths(paths)
        save_shelf(paths)
        self.changed.emit()

    def _menu(self, pos):
        if not (sel := self.list.paths(selected=True)):
            return
        m = QMenu(self)
        m.addAction("Remove from shelf", lambda: self.remove(sel))
        m.addAction("Show in Explorer", lambda: _select(sel))
        m.exec(QCursor.pos())

    def count(self) -> int:
        return self.list.count()


# ---------- Clipboard ----------
class ClipTab(QWidget):
    """The last few things you copied (text and images). Click Copy to put one back on the clipboard;
    images can be saved as files. Content that password managers mark as private is never kept, and
    nothing here is written to disk."""
    KEEP = 6
    image_copied = Signal(QImage)

    def __init__(self):
        super().__init__()
        self.items, self.ignore_next = [], False
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(0, 0, 0, 0)
        self.lay.setSpacing(3)
        self.empty = muted("Things you copy show up here.")
        self.lay.addWidget(self.empty)
        self.lay.addStretch()
        QApplication.clipboard().dataChanged.connect(self._changed)

    def _changed(self):
        if self.ignore_next:  # our own "Copy" button
            self.ignore_next = False
            return
        md = QApplication.clipboard().mimeData()
        if any("ExcludeClipboardContentFromMonitorProcessing" in f or "CanIncludeInClipboardHistory" in f
               for f in md.formats()):
            return
        if md.hasUrls():
            return  # copied files, not content
        if md.hasImage():
            img = QApplication.clipboard().image()
            if not img.isNull():
                self._add({"image": img})
                self.image_copied.emit(img)
        elif md.hasText() and (text := md.text().strip()):
            self._add({"text": text})

    def _add(self, item):
        item["time"] = time.strftime("%H:%M")
        same = lambda i: "text" in item and i.get("text") == item["text"]  # noqa: E731
        self.items = [item, *[i for i in self.items if not same(i)]][:self.KEEP]
        _clear_rows(self.lay, keep_last=2)  # keep the empty label and the stretch
        self.empty.setVisible(not self.items)
        for i, it in enumerate(self.items):
            self.lay.insertWidget(i, self._row(it))

    def _row(self, it):
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        if "image" in it:
            thumb = QLabel()
            thumb.setPixmap(QPixmap.fromImage(it["image"]).scaled(48, 28, Qt.KeepAspectRatio, Qt.SmoothTransformation))
            h.addWidget(thumb)
            h.addWidget(muted(f"Image {it['image'].width()} × {it['image'].height()} · {it['time']}"), 1)
            h.addWidget(button("Save", lambda: _select([self.save(it["image"])])))
        else:
            text = it["text"].replace("\n", " ")
            h.addWidget(QLabel(text[:70] + ("…" if len(text) > 70 else "")), 1)
            h.addWidget(muted(it["time"]))
        h.addWidget(button("Copy", lambda: self.copy(it)))
        return row

    def copy(self, it):
        self.ignore_next = True
        cb = QApplication.clipboard()
        if "image" in it:
            cb.setImage(it["image"])
        else:
            cb.setText(it["text"])

    @staticmethod
    def save(img, stem="Clipboard") -> Path:
        from ..clip import CLIP_DIR, save_image
        return save_image(img, CLIP_DIR, stem)


# ---------- Recent ----------
class RecentTab(QWidget):
    """Latest results from History: drag them out, or undo the last one."""
    SHOW = 6

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.list = FileList()
        lay.addWidget(self.list, 1)
        self.foot = QHBoxLayout()
        lay.addLayout(self.foot)
        self.refresh()

    def refresh(self):
        from .. import history
        entries = [e for e in history.load() if e["outputs"]][:self.SHOW]
        self.list.set_paths([o for e in entries for o in e["outputs"] if Path(o).exists()][:12])
        while self.foot.count():
            if w := self.foot.takeAt(0).widget():
                w.setParent(None)
                w.deleteLater()
        if entries:
            e = entries[0]
            self.foot.addWidget(muted(f"Last: {e['title']} · {e['time']}"), 1)
            self.foot.addWidget(button("Undo", lambda: self._undo(e.get("key"))))
        else:
            self.foot.addWidget(muted("Results you make show up here, ready to drag out."), 1)

    def _undo(self, key):
        from .. import history
        history.undo(key)
        self.refresh()


# ---------- Phone ----------
class PhoneTab(QWidget):
    """QR code in the notch: the phone downloads the shared files and can send files back.
    Sharing lives only while the QR is on screen; `stopped` fires when Stop (or the idle limit) ends it."""
    received = Signal(str)
    stopped = Signal()
    IDLE_MS = 10 * 60_000  # forgotten QR: stop after 10 minutes without a file from the phone

    def __init__(self):
        super().__init__()
        self.share = None
        self.idle = QTimer(self, singleShot=True, interval=self.IDLE_MS, timeout=self._end)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.qr = QLabel()
        self.qr.setFixedSize(162, 162)
        lay.addWidget(self.qr, 0, Qt.AlignTop)
        right = QVBoxLayout()
        self.title = QLabel()
        self.hint = muted("")
        self.hint.setWordWrap(True)
        self.got = FileList()
        self.got.setMaximumHeight(90)
        row = QHBoxLayout()
        self.start_btn = button("Receive from phone", lambda: self.start([]), primary=True)
        self.stop_btn = button("Stop", self._end)
        row.addWidget(self.start_btn)
        row.addWidget(self.stop_btn)
        row.addStretch()
        for w in (self.title, self.hint, self.got):
            right.addWidget(w)
        right.addLayout(row)
        lay.addLayout(right, 1)
        self.received.connect(lambda p: (self.got.set_paths(self.got.paths() + [p]), self.idle.start()))
        self._idle()

    def start(self, files):
        """Raises RuntimeError when the PC isn't on a network (shown by the notch)."""
        from .. import phone
        from .extras import qr_pixmap
        self.stop()
        self.share = phone.Share(files, on_receive=lambda p: self.received.emit(str(p)))
        self.qr.setPixmap(qr_pixmap(self.share.url, 150))
        self.qr.setStyleSheet("background:white;border-radius:10px;padding:6px")
        self.qr.show()
        self.title.setText(f"Sending {len(files)} file{'s' * (len(files) != 1)}" if files else "Waiting for your phone")
        self.hint.setText("Scan with the phone camera (same Wi-Fi). Files from the phone land in Downloads\\PomeloO."
                          + (" Tap a file on the phone to download it." if files else ""))
        self.start_btn.hide()
        self.stop_btn.show()
        self.idle.start()

    def stop(self):
        self.idle.stop()
        if self.share:
            self.share.close()
            self.share = None
        self._idle()

    def _end(self):
        self.stop()
        self.stopped.emit()

    def _idle(self):
        self.qr.hide()
        self.title.setText("Phone")
        self.hint.setText("Receive files from your phone, or drop files on the notch's Phone zone to send them.")
        self.start_btn.show()
        self.stop_btn.hide()

    def active(self) -> bool:
        return self.share is not None
