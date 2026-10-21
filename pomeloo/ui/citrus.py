"""Citrus-slice progress: segments of a cut orange fill one by one as files convert."""
import math

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen, QRadialGradient
from PySide6.QtWidgets import QWidget

SEGMENTS = 12


def icon_pixmap(size: int) -> "QPixmap":
    """App icon: the progress slice with each segment's opacity stepping from transparent to solid."""
    from PySide6.QtGui import QPixmap
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    g = QPainter(pm)
    g.setRenderHint(QPainter.Antialiasing)
    s = float(size)
    c = QPointF(s / 2, s / 2)
    R = s / 2 - max(0.5, s * 0.02)
    rind = QRadialGradient(c - QPointF(R * 0.3, R * 0.3), R * 1.6)
    rind.setColorAt(0, QColor("#ffb54a"))
    rind.setColorAt(1, QColor("#e2620a"))
    g.setPen(Qt.NoPen)
    g.setBrush(rind)
    g.drawEllipse(c, R, R)
    pith = R * 0.9
    g.setCompositionMode(QPainter.CompositionMode_Clear)  # see-through slice under the segments
    g.drawEllipse(c, pith, pith)
    g.setCompositionMode(QPainter.CompositionMode_SourceOver)
    g.setBrush(QColor("#fff1db"))
    g.drawEllipse(c, pith, pith)
    g.setCompositionMode(QPainter.CompositionMode_Clear)
    flesh = R * 0.84
    g.drawEllipse(c, flesh, flesh)
    g.setCompositionMode(QPainter.CompositionMode_SourceOver)
    hub = max(1.0, R * 0.09)
    step, gap = 360 / SEGMENTS, (4.0 if s >= 48 else 6.0)
    juice = QRadialGradient(c, flesh)
    juice.setColorAt(0.0, QColor("#ffe2a1"))
    juice.setColorAt(0.45, QColor("#ffa62b"))
    juice.setColorAt(1.0, QColor("#ff7b00"))
    for i in range(SEGMENTS):
        a0 = 90 - (i + 1) * step + gap / 2
        a1 = 90 - i * step - gap / 2
        g.setOpacity(i / (SEGMENTS - 1))  # 0 % ... 100 %, clockwise from 12 o'clock
        g.setBrush(juice)
        g.drawPath(CitrusProgress._wedge(c, hub, flesh, a0, a1))
    g.setOpacity(1.0)
    g.setBrush(QColor("#fff1db"))
    g.drawEllipse(c, hub, hub)
    g.end()
    return pm


def write_ico(path):
    """Multi-size .ico, each size rendered natively so small icons stay crisp."""
    import io
    from PIL import Image
    from PySide6.QtCore import QBuffer, QIODevice
    images = []
    for n in (256, 128, 64, 48, 32, 24, 16):
        buf = QBuffer()
        buf.open(QIODevice.WriteOnly)
        icon_pixmap(n).save(buf, "PNG")
        images.append(Image.open(io.BytesIO(bytes(buf.data()))).convert("RGBA"))
    images[0].save(path, format="ICO", sizes=[im.size for im in images], append_images=images[1:])


class CitrusProgress(QWidget):
    """set_value(0..1) animates toward the target; the next segment pulses while work is running."""

    def __init__(self, size=176):
        super().__init__()
        self.setFixedSize(size, size)
        self.target = self.value = 0.0
        self.running, self.phase, self.pop = True, 0.0, 0.0
        self._timer = QTimer(self, interval=16, timeout=self._tick)
        self._timer.start()

    def hideEvent(self, e):  # a closed progress window must not keep animating (idle CPU)
        self._timer.stop()
        super().hideEvent(e)

    def showEvent(self, e):
        self._timer.start()
        super().showEvent(e)

    def set_value(self, v: float):
        self.target = min(1.0, max(0.0, v))

    def finish(self):
        self.running, self.target, self.pop = False, 1.0, 1.0

    def _tick(self):
        self.value += (self.target - self.value) * 0.16  # ease toward the real progress
        if abs(self.target - self.value) < 0.0005:
            self.value = self.target
        self.phase = (self.phase + 0.06) % (2 * math.pi)
        self.pop = max(0.0, self.pop - 0.035)
        self.update()

    # ---------- painting ----------
    @staticmethod
    def _wedge(c: QPointF, r0: float, r1: float, a0: float, a1: float) -> QPainterPath:
        """Annular sector between radii r0..r1 and angles a0..a1 (degrees, Qt convention)."""
        p = QPainterPath()
        outer = QRectF(c.x() - r1, c.y() - r1, 2 * r1, 2 * r1)
        inner = QRectF(c.x() - r0, c.y() - r0, 2 * r0, 2 * r0)
        p.arcMoveTo(outer, a0)
        p.arcTo(outer, a0, a1 - a0)
        p.arcTo(inner, a1, a0 - a1)
        p.closeSubpath()
        return p

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        s = self.width()
        c = QPointF(s / 2, s / 2)
        bump = math.sin(self.pop * math.pi) * 0.06  # little "pop" when finished
        g.translate(c)
        g.scale(1 + bump, 1 + bump)
        g.translate(-c)
        R = s / 2 - 6
        # rind: glossy orange ring, then white pith
        rind = QRadialGradient(c - QPointF(R * 0.3, R * 0.3), R * 1.6)
        rind.setColorAt(0, QColor("#ffb54a"))
        rind.setColorAt(1, QColor("#e2620a"))
        g.setPen(Qt.NoPen)
        g.setBrush(rind)
        g.drawEllipse(c, R, R)
        g.setBrush(QColor("#fff1db"))
        g.drawEllipse(c, R - 7, R - 7)
        flesh_r, hub = R - 11, 7.0
        g.setBrush(QColor(48, 40, 34))  # empty slice, seen through
        g.drawEllipse(c, flesh_r + 1, flesh_r + 1)
        step = 360 / SEGMENTS
        gap = 2.2  # pith between segments (degrees)
        filled = self.value * SEGMENTS
        juice = QRadialGradient(c, flesh_r)
        juice.setColorAt(0.0, QColor("#ffe2a1"))
        juice.setColorAt(0.45, QColor("#ffa62b"))
        juice.setColorAt(1.0, QColor("#ff7b00"))
        for i in range(SEGMENTS):
            a0 = 90 - (i + 1) * step + gap / 2  # first segment at 12 o'clock, clockwise
            a1 = 90 - i * step - gap / 2
            frac = min(1.0, max(0.0, filled - i))
            empty = self._wedge(c, hub, flesh_r, a0, a1)
            if frac < 1:
                pulse = self.running and i == int(filled)
                alpha = 26 + (22 * (0.5 + 0.5 * math.sin(self.phase)) if pulse else 0)
                g.setBrush(QColor(255, 190, 120, int(alpha)))
                g.drawPath(empty)
            if frac > 0:  # segment grows from the centre outward
                g.setBrush(juice)
                g.drawPath(self._wedge(c, hub, hub + (flesh_r - hub) * frac, a0, a1))
                mid = math.radians((a0 + a1) / 2)  # juicy highlight streak along the segment
                g.setPen(QPen(QColor(255, 255, 255, 70), 1.4, Qt.SolidLine, Qt.RoundCap))
                inner = hub + 6
                outer = hub + (flesh_r - hub) * frac * 0.85
                if outer > inner:
                    g.drawLine(QPointF(c.x() + math.cos(mid) * inner, c.y() - math.sin(mid) * inner),
                               QPointF(c.x() + math.cos(mid) * outer, c.y() - math.sin(mid) * outer))
                g.setPen(Qt.NoPen)
        g.setBrush(QColor("#fff1db"))  # pith hub
        g.drawEllipse(c, hub, hub)
        g.setBrush(QColor(255, 255, 255, 40))  # rind gloss
        g.drawEllipse(QPointF(c.x() - R * 0.45, c.y() - R * 0.62), R * 0.18, R * 0.07)
        g.end()
