"""Visual editors used by the tool dialogs: shape/region canvas, media scrubber, ordering lists."""
from pathlib import Path

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, QUrl, Signal
from PySide6.QtGui import QColor, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QFileDialog, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
                               QPushButton, QVBoxLayout, QWidget)

PREVIEW = 520


def pil_to_pixmap(img) -> QPixmap:
    img = img.convert("RGBA")
    return QPixmap.fromImage(QImage(img.tobytes(), img.width, img.height, QImage.Format_RGBA8888).copy())


def fmt_time(t: float) -> str:
    return f"{int(t // 60):02}:{t % 60:06.3f}"


# ---------- region / shape canvas ----------
class ShapeCanvas(QLabel):
    """mode 'rect' | 'rects': drag to draw, drag inside a region to move it, right-click to delete.
    mode 'shapes': annotation tools rendered with the real engine (what you see is what you get)."""
    changed = Signal()

    def __init__(self, base_img, mode):
        super().__init__()
        self.base = base_img.convert("RGBA")
        self.base.thumbnail((PREVIEW, PREVIEW))
        self.setPixmap(pil_to_pixmap(self.base))
        self.setFixedSize(*self.base.size)
        self.mode, self.rects, self.shapes = mode, [], []
        self.kind, self.color, self.pen, self.text, self.image_path = "arrow", "#ff3b30", 6, "", ""
        self.aspect = None  # width/height ratio lock in pixels
        self._drag = self._move = None

    # helpers
    def _frac(self, p):
        W, H = self.base.size
        return min(max(p.x() / W, 0), 1), min(max(p.y() / H, 0), 1)

    def _hit(self, f):
        for i in range(len(self.rects) - 1, -1, -1):
            x, y, w, h = self.rects[i]
            if x <= f[0] <= x + w and y <= f[1] <= y + h:
                return i
        return None

    def add_rects(self, rects):
        self.rects += [list(r) for r in rects]
        self.update()
        self.changed.emit()

    def _render(self):
        if self.mode == "shapes":
            from ..tools.image import draw_shapes
            self.setPixmap(pil_to_pixmap(draw_shapes(self.base, self.shapes)))
        self.update()
        self.changed.emit()

    # mouse
    def mousePressEvent(self, e):
        f = self._frac(e.position())
        if e.button() == Qt.RightButton:
            if self.mode == "shapes":
                if self.shapes:
                    self.shapes.pop()
            elif (i := self._hit(f)) is not None:
                self.rects.pop(i)
            return self._render()
        if self.mode == "shapes":
            n = sum(1 for s in self.shapes if s["kind"] == "number") + 1
            shape = {"kind": self.kind, "color": self.color, "width": self.pen, "points": [list(f), list(f)]}
            if self.kind == "text":
                if not self.text:
                    return
                shape["text"] = self.text
            elif self.kind == "number":
                shape["n"] = n
            elif self.kind == "image":
                if not self.image_path:
                    return
                shape["path"] = self.image_path
            if self.kind == "pen" or self.kind == "highlight":
                shape["points"] = [list(f)]
            self.shapes.append(shape)
            return self._render()
        i = self._hit(f)
        if i is not None:
            self._move = (i, f, list(self.rects[i]))
        else:
            if self.mode == "rect":
                self.rects = []
            self.rects.append([f[0], f[1], 0, 0])
            self._drag = f

    def mouseMoveEvent(self, e):
        if not e.buttons() & Qt.LeftButton:
            return
        f = self._frac(e.position())
        if self.mode == "shapes" and self.shapes:
            s = self.shapes[-1]
            if s["kind"] in ("pen", "highlight"):
                s["points"].append(list(f))
            elif s["kind"] not in ("text", "number"):
                s["points"][-1] = list(f)
            return self._render()
        if self._move:
            i, start, (x, y, w, h) = self._move
            self.rects[i] = [min(max(x + f[0] - start[0], 0), 1 - w), min(max(y + f[1] - start[1], 0), 1 - h), w, h]
        elif self._drag:
            (x0, y0), (x1, y1) = self._drag, f
            w, h = abs(x1 - x0), abs(y1 - y0)
            if self.aspect:  # keep the pixel aspect while dragging
                W, H = self.base.size
                h = min(1.0, w * W / self.aspect / H)
                w = h * H * self.aspect / W
            self.rects[-1] = [x0 if x1 >= x0 else x0 - w, y0 if y1 >= y0 else y0 - h, w, h]
        self.update()

    def mouseReleaseEvent(self, e):
        if self._drag and self.rects and self.rects[-1][2] < 0.005:
            self.rects.pop()  # a click, not a drag
        self._drag = self._move = None
        self.changed.emit()

    def paintEvent(self, e):
        super().paintEvent(e)
        if self.mode == "shapes":
            return
        g = QPainter(self)
        W, H = self.base.size
        for i, (x, y, w, h) in enumerate(self.rects):
            g.setPen(QPen(QColor("#ff8a00"), 2))
            g.setBrush(QColor(255, 138, 0, 60))
            g.drawRect(QRectF(x * W, y * H, w * W, h * H))
            if self.mode == "rects":
                g.drawText(QPointF(x * W + 4, y * H + 14), str(i + 1))
        g.end()


def shape_toolbar(canvas: ShapeCanvas, parent) -> QWidget:
    """Tool buttons for annotate: pen, highlight, arrow, line, rect, ellipse, number, text, magnify, image."""
    from PySide6.QtWidgets import QButtonGroup, QColorDialog, QLineEdit, QSpinBox
    w = QWidget()
    lay = QVBoxLayout(w)
    lay.setContentsMargins(0, 0, 0, 0)
    row, group = QHBoxLayout(), QButtonGroup(w)
    for kind in ("pen", "highlight", "arrow", "line", "rect", "ellipse", "number", "text", "magnify", "image"):
        b = QPushButton(kind.capitalize(), checkable=True, checked=kind == canvas.kind)
        group.addButton(b)

        def pick(_=False, k=kind):
            canvas.kind = k
            if k == "image" and not canvas.image_path:
                canvas.image_path = QFileDialog.getOpenFileName(parent, "Image to place", "",
                                                                "Images (*.png *.jpg *.jpeg *.webp *.heic *.bmp)")[0]
        b.clicked.connect(pick)
        row.addWidget(b)
    lay.addLayout(row)
    row2 = QHBoxLayout()
    txt = QLineEdit(placeholderText="Text for the Text tool")
    txt.textChanged.connect(lambda s: setattr(canvas, "text", s))
    col = QPushButton("Colour")
    col.setStyleSheet(f"background:{canvas.color}")

    def color():
        c = QColorDialog.getColor(QColor(canvas.color), parent)
        if c.isValid():
            canvas.color = c.name()
            col.setStyleSheet(f"background:{c.name()}")
    col.clicked.connect(color)
    width = QSpinBox(minimum=1, maximum=40, value=canvas.pen, prefix="Width ")
    width.valueChanged.connect(lambda v: setattr(canvas, "pen", v))
    for x in (txt, col, width):
        row2.addWidget(x)
    lay.addLayout(row2)
    return w


# ---------- media scrubber ----------
class Timeline(QWidget):
    seek = Signal(float)

    def __init__(self, duration, waveform: QPixmap | None = None):
        super().__init__()
        self.duration, self.wave, self.pos = max(duration, 0.001), waveform, 0.0
        self.mark_in = self.mark_out = None
        self.ranges, self.points = [], []
        self.setMinimumSize(480, 70 if waveform else 34)

    def _x(self, t):
        return t / self.duration * self.width()

    def mousePressEvent(self, e):
        self.seek.emit(min(max(e.position().x() / self.width(), 0), 1) * self.duration)

    mouseMoveEvent = mousePressEvent

    def paintEvent(self, _):
        g = QPainter(self)
        r = self.rect()
        g.fillRect(r, QColor(40, 40, 44))
        if self.wave:
            g.drawPixmap(r, self.wave)
        for a, b in self.ranges:
            g.fillRect(QRectF(self._x(a), 0, self._x(b) - self._x(a), r.height()), QColor(255, 59, 48, 90))
        if self.mark_in is not None:
            b = self.mark_out if self.mark_out is not None else self.duration
            g.fillRect(QRectF(self._x(self.mark_in), 0, self._x(b) - self._x(self.mark_in), r.height()),
                       QColor(255, 138, 0, 70))
        g.setPen(QPen(QColor("#34c759"), 2))
        for t in self.points:
            g.drawLine(QPointF(self._x(t), 0), QPointF(self._x(t), r.height()))
        g.setPen(QPen(QColor("white"), 2))
        g.drawLine(QPointF(self._x(self.pos), 0), QPointF(self._x(self.pos), r.height()))
        g.end()


class MediaScrubber(QWidget):
    """Video/audio preview with frame stepping, waveform, and marks.
    mode: 'range' (In/Out), 'ranges' (add several In/Out ranges), 'times' (add time points)."""
    changed = Signal()

    def __init__(self, path, mode="range"):
        super().__init__()
        from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
        from ..engines.media import probe
        self.path, self.mode = Path(path), mode
        info = probe(path)
        self.duration, self.frame = info["duration"], 1 / (info["fps"] or 30)
        lay = QVBoxLayout(self)
        self.player, self.audio = QMediaPlayer(self), QAudioOutput(self)
        self.player.setAudioOutput(self.audio)
        if info["has_video"]:
            from PySide6.QtMultimediaWidgets import QVideoWidget
            self.video = QVideoWidget()
            self.video.setMinimumSize(400, 225)
            self.player.setVideoOutput(self.video)
            lay.addWidget(self.video)
        wave = None
        if not info["has_video"]:
            import tempfile
            from ..tools.media import waveform_png
            wave = QPixmap(str(waveform_png(path, Path(tempfile.mkdtemp()) / "wave.png")))
        self.timeline = Timeline(self.duration, wave)
        self.timeline.seek.connect(lambda t: self.player.setPosition(int(t * 1000)))
        lay.addWidget(self.timeline)
        self.label = QLabel()
        self.player.positionChanged.connect(self._pos)
        row = QHBoxLayout()
        for text, fn in (("◀ frame", lambda: self._step(-1)), ("▶ / ❚❚", self.toggle), ("frame ▶", lambda: self._step(1))):
            b = QPushButton(text)
            b.clicked.connect(fn)
            row.addWidget(b)
        row.addWidget(self.label)
        row.addStretch()
        actions = {"range": [("Set In", self.set_in), ("Set Out", self.set_out)],
                   "ranges": [("Set In", self.set_in), ("Set Out", self.set_out), ("Add range", self.add_range),
                              ("Clear", self.clear)],
                   "times": [("Add this frame", self.add_point), ("Clear", self.clear)]}[mode]
        for text, fn in actions:
            b = QPushButton(text)
            b.clicked.connect(fn)
            row.addWidget(b)
        lay.addLayout(row)
        self.load(self.path)
        if mode == "range":
            self.timeline.mark_in, self.timeline.mark_out = 0.0, self.duration

    def load(self, path):
        self.player.setSource(QUrl.fromLocalFile(str(path)))
        self.player.pause()
        self.player.setPosition(1)  # renders the first frame while paused

    def toggle(self):
        from PySide6.QtMultimedia import QMediaPlayer
        (self.player.pause if self.player.playbackState() == QMediaPlayer.PlayingState else self.player.play)()

    def _step(self, n):
        self.player.pause()
        self.player.setPosition(max(0, int((self.now() + n * self.frame) * 1000)))

    def _pos(self, ms):
        self.timeline.pos = ms / 1000
        self.label.setText(f"{fmt_time(ms / 1000)} / {fmt_time(self.duration)}")
        self.timeline.update()

    def now(self) -> float:
        return self.player.position() / 1000

    def set_in(self):
        self.timeline.mark_in = self.now()
        if self.timeline.mark_out is not None and self.timeline.mark_out <= self.now():
            self.timeline.mark_out = None
        self._changed()

    def set_out(self):
        self.timeline.mark_out = self.now()
        if self.timeline.mark_in is None or self.timeline.mark_in >= self.now():
            self.timeline.mark_in = 0.0
        self._changed()

    def add_range(self):
        a, b = self.timeline.mark_in, self.timeline.mark_out
        if a is not None and b is not None and b > a:
            self.timeline.ranges.append([round(a, 3), round(b, 3)])
            self.timeline.mark_in = self.timeline.mark_out = None
        self._changed()

    def add_point(self):
        self.timeline.points = sorted({*self.timeline.points, round(self.now(), 3)})
        self._changed()

    def clear(self):
        self.timeline.ranges, self.timeline.points = [], []
        self._changed()

    def _changed(self):
        self.timeline.update()
        self.changed.emit()

    # values
    def start(self):
        return round(self.timeline.mark_in or 0.0, 3)

    def end(self):
        return round(self.timeline.mark_out if self.timeline.mark_out is not None else self.duration, 3)

    def ranges(self):
        return list(self.timeline.ranges)

    def points(self):
        return list(self.timeline.points)


# ---------- ordering ----------
class FileOrder(QListWidget):
    """Drag to reorder the selection (Merge PDFs, Join videos, Collage, Create PDF)."""

    def __init__(self, paths):
        super().__init__()
        self.setDragDropMode(QListWidget.InternalMove)
        self.setMinimumHeight(min(60 + 22 * len(paths), 240))
        for p in paths:
            it = QListWidgetItem(Path(p).name)
            it.setData(Qt.UserRole, str(p))
            self.addItem(it)

    def paths(self):
        return [self.item(i).data(Qt.UserRole) for i in range(self.count())]


class PagesEditor(QWidget):
    """Organize PDF: reorder (drag), rotate, duplicate, delete pages."""

    def __init__(self, pdf_path):
        super().__init__()
        import pymupdf as fitz
        lay = QVBoxLayout(self)
        self.list = QListWidget(viewMode=QListWidget.IconMode, movement=QListWidget.Snap)
        self.list.setDragDropMode(QListWidget.InternalMove)
        self.list.setIconSize(QSize(110, 150))
        self.list.setMinimumSize(560, 360)
        self.list.setSelectionMode(QListWidget.ExtendedSelection)
        for i, page in enumerate(fitz.open(pdf_path)):
            pix = page.get_pixmap(dpi=30)
            img = QImage(pix.samples, pix.width, pix.height, pix.stride, QImage.Format_RGB888).copy()
            self._add(QPixmap.fromImage(img), i, 0)
        row = QHBoxLayout()
        for label, fn in (("Rotate 90°", self.rotate), ("Duplicate", self.duplicate), ("Delete", self.delete)):
            b = QPushButton(label)
            b.clicked.connect(fn)
            row.addWidget(b)
        lay.addWidget(QLabel("Drag pages to reorder. Select pages to rotate, duplicate or delete."))
        lay.addWidget(self.list)
        lay.addLayout(row)

    def _add(self, icon, src, rot, row=None):
        it = QListWidgetItem(icon, "")
        it.setData(Qt.UserRole, src)
        it.setData(Qt.UserRole + 1, rot)
        it.setText(f"{src + 1}" + (f" ⟳{rot}°" if rot else ""))
        self.list.insertItem(self.list.count() if row is None else row, it)

    def rotate(self):
        for it in self.list.selectedItems():
            rot = (it.data(Qt.UserRole + 1) + 90) % 360
            it.setData(Qt.UserRole + 1, rot)
            it.setText(f"{it.data(Qt.UserRole) + 1}" + (f" ⟳{rot}°" if rot else ""))

    def duplicate(self):
        for it in self.list.selectedItems():
            self._add(it.icon(), it.data(Qt.UserRole), it.data(Qt.UserRole + 1), self.list.row(it) + 1)

    def delete(self):
        for it in self.list.selectedItems():
            self.list.takeItem(self.list.row(it))

    def order(self):
        return [self.list.item(i).data(Qt.UserRole) for i in range(self.list.count())]

    def rotations(self):
        return {str(i): self.list.item(i).data(Qt.UserRole + 1) for i in range(self.list.count())
                if self.list.item(i).data(Qt.UserRole + 1)}
