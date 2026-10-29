"""Copy text from the screen: hotkey -> drag over it -> the text (or a QR code's contents) is on the clipboard.

The overlay is built once and kept hidden so it appears instantly; the OCR engine is warmed up at
start (tools/detect.warm_up). A freshly copied image (last 30 s) is read directly, without a snip."""
import threading
import time

from PySide6.QtCore import QObject, QPoint, QRect, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QGuiApplication, QImage, QPainter, QPen
from PySide6.QtWidgets import QApplication, QLabel, QVBoxLayout, QWidget

FRESH = 30  # seconds a copied image counts as "just copied"


class Toast(QWidget):
    """Small pill near the cursor that fades away by itself (big and centered in Exhibition mode)."""
    big = False

    def __init__(self):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool | Qt.WindowTransparentForInput)
        from .windows import PILL
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(4, 4, 4, 4)
        self.label = QLabel()
        self.label.setStyleSheet(PILL)
        lay.addWidget(self.label)
        self.timer = QTimer(self, singleShot=True, interval=1800, timeout=self.hide)

    def show_text(self, text):
        from .windows import PILL
        self.label.setText(text)
        self.label.setStyleSheet(PILL + (" font-size: 26px; padding: 10px 26px;" if self.big else ""))
        self.adjustSize()
        if self.big:
            g = (QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()).geometry()
            self.move(g.center() - self.rect().center())
        else:
            self.move(QCursor.pos() + QPoint(16, 18))
        self.show()
        self.raise_()
        self.timer.start()


class Snip(QWidget):
    """Full-screen frozen screenshot of the monitor under the cursor; drag a box, Esc cancels."""
    picked = Signal(QImage)

    def __init__(self):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setCursor(Qt.CrossCursor)
        self.shot, self.a, self.b = None, None, None

    def start(self):
        screen = QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        self.shot = screen.grabWindow(0)
        self.a = self.b = None
        self.setGeometry(screen.geometry())
        self.show()
        self.raise_()
        self.activateWindow()

    def _rect(self) -> QRect:
        return QRect(self.a, self.b).normalized() if self.a and self.b else QRect()

    def paintEvent(self, _):
        g = QPainter(self)
        g.drawPixmap(self.rect(), self.shot)
        r = self._rect()
        dim = QColor(0, 0, 0, 110)
        if r.isNull():
            g.fillRect(self.rect(), dim)
        else:  # dim everything but the box
            for part in (QRect(0, 0, self.width(), r.top()), QRect(0, r.bottom() + 1, self.width(), self.height()),
                         QRect(0, r.top(), r.left(), r.height()), QRect(r.right() + 1, r.top(), self.width(), r.height())):
                g.fillRect(part, dim)
            g.setPen(QPen(QColor("#ff8a00"), 2))
            g.drawRect(r)
        g.setPen(QColor(255, 255, 255, 220))
        g.drawText(self.rect().adjusted(0, 24, 0, 0), Qt.AlignHCenter | Qt.AlignTop,
                   "Drag over text or a QR code to copy it  ·  Esc to cancel")
        g.end()

    def mousePressEvent(self, e):
        if e.button() != Qt.LeftButton:
            return self.hide()
        self.a = self.b = e.position().toPoint()

    def mouseMoveEvent(self, e):
        if self.a:
            self.b = e.position().toPoint()
            self.update()

    def mouseReleaseEvent(self, e):
        r = self._rect()
        self.hide()
        if r.width() > 4 and r.height() > 4:
            dpr = self.shot.devicePixelRatio()
            self.picked.emit(self.shot.copy(QRect(r.topLeft() * dpr, r.size() * dpr)).toImage())

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.hide()


def _to_pil(img: QImage):
    from PIL import Image
    img = img.convertToFormat(QImage.Format_RGB888)
    return Image.frombuffer("RGB", (img.width(), img.height()), bytes(img.constBits()), "raw", "RGB",
                            img.bytesPerLine(), 1).copy()


def _bleach(pil):
    """Colored pixels -> white. Posters often print a QR straight onto a dark colored background with no
    white margin, so its corner squares merge into the background; this gives the code its margin back."""
    import numpy as np
    from PIL import Image
    a = np.asarray(pil.convert("RGB"))
    out = a.copy()
    out[a.max(2).astype(np.int16) - a.min(2) > 48] = 255
    return Image.fromarray(out)


def read_codes(pil) -> list[str]:
    """QR / barcode contents, in reading order, without repeats."""
    import zxingcpp
    from PIL import Image
    codes = [b.text for b in zxingcpp.read_barcodes(pil) if b.text]
    if not codes and max(pil.size) < 1000:  # a small QR on screen reads better enlarged
        big = pil.resize((pil.width * 2, pil.height * 2), Image.NEAREST)
        codes = [b.text for b in zxingcpp.read_barcodes(big) if b.text]
    if not codes:
        codes = [b.text for b in zxingcpp.read_barcodes(_bleach(pil)) if b.text]
    return list(dict.fromkeys(codes))


def read_image(pil) -> tuple[str, bool]:
    """(text, is_code): a QR / barcode's contents if there is one, otherwise the OCR text."""
    from ..tools.detect import ocr_text
    codes = read_codes(pil)
    return ("\n".join(codes), True) if codes else (ocr_text(pil), False)


class ScreenText(QObject):
    done = Signal(str, bool, str)  # text, is_code, error

    def __init__(self):
        super().__init__()
        self.snip, self.toast, self.image_at = Snip(), Toast(), 0.0
        self.snip.picked.connect(self.read)
        self.done.connect(self._finish)
        QApplication.clipboard().dataChanged.connect(self._clip_changed)

    def _clip_changed(self):
        if QApplication.clipboard().mimeData().hasImage():
            self.image_at = time.monotonic()

    def trigger(self):
        if time.monotonic() - self.image_at < FRESH and QApplication.clipboard().mimeData().hasImage():
            self.image_at = 0.0  # once
            return self.read(QApplication.clipboard().image())
        self.snip.start()

    def read(self, img: QImage):
        pil = _to_pil(img)

        def work():
            try:
                self.done.emit(*read_image(pil), "")
            except Exception as e:  # shown in the toast, never swallowed
                self.done.emit("", False, str(e) or e.__class__.__name__)
        threading.Thread(target=work, daemon=True).start()

    def _finish(self, text, is_code, err):
        if err:
            return self.toast.show_text(f"Couldn't read it: {err}")
        if not text:
            return self.toast.show_text("No text found")
        QApplication.clipboard().setText(text)
        if is_code:
            link = text.startswith(("http://", "https://"))
            return self.toast.show_text(f"Copied QR {'link' if link else 'code'} · {text[:48]}")
        words = len(text.split())
        self.toast.show_text(f"Copied · {words} word{'s' * (words != 1)}")
