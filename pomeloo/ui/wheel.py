"""Radial wheel: a frameless drop target/menu shown at the cursor."""
import math

from PySide6.QtCore import QPoint, QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QApplication, QWidget

from ..catalog import ACTIONS, TOOLS, selection_ext, targets, tools

S = 1.3  # base geometry in px, scaled up for desktop
INNER, OUTER, GAP = 50.6 * S, 119.5 * S, 4 * S
SIZE = int(2 * (OUTER + 10))
HINT_H = 54
ORANGE = QColor("#ff8a00")
MODES = ["convert", "tools", "actions"]
MODE_NAMES = {"convert": "Convert", "tools": "Tools", "actions": "Actions"}


def label_of(fmt: str) -> str:
    return "GZIP" if fmt == "gz" else fmt.upper()


def angle(i: int, n: int) -> float:
    return (math.pi if n == 3 else math.pi / 2) - 2 * math.pi * i / n


class Wheel(QWidget):
    chosen = Signal(str, str, list)  # mode, item id, paths

    def __init__(self, settings, play_tick=lambda: None):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.settings, self.play_tick = settings, play_tick
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAcceptDrops(True)
        self.setMouseTracking(True)
        self.setFixedSize(SIZE, SIZE + HINT_H)
        self.paths: list[str] = []
        self.mode, self.items, self.hover, self.keyboard = "convert", [], None, False
        self._leave = QTimer(self, singleShot=True, interval=350, timeout=self.close_wheel)

    # ---------- opening ----------
    def _place(self, pos: QPoint):
        self.move(pos - QPoint(SIZE // 2, SIZE // 2))

    def open_drag(self, pos: QPoint, mode="convert"):
        """Shown under the cursor during an Explorer drag; files arrive via dragEnterEvent."""
        self.keyboard, self.paths, self.items = False, [], []
        self._set_mode(mode)
        self._place(pos)
        self.show()
        self.raise_()

    def open_keyboard(self, pos: QPoint, paths, mode="convert"):
        self.keyboard, self.paths, self.items = True, list(paths), []
        self._set_mode(mode)
        self._place(pos)
        self.show()
        self.raise_()
        self.activateWindow()
        self.setFocus()

    def close_wheel(self):
        self.hide()
        self.hover = None

    # ---------- model ----------
    def _set_mode(self, mode):
        if mode == self.mode and self.items:
            return
        self.mode = mode
        ext = selection_ext(self.paths) if self.paths else None
        if mode == "actions":
            self.items = [(a, v[0]) for a, v in ACTIONS.items()]
        elif not ext:
            self.items = []
        elif mode == "convert":
            self.items = [(t, label_of(t)) for t in targets(ext)]
        else:
            self.items = [(t, TOOLS[t][0]) for t in tools(ext, len(self.paths))]
        self.hover = 0 if self.keyboard and self.items else None
        self.update()

    def mode_for_modifiers(self, mods) -> str | None:
        held = [k for k, flag in (("shift", Qt.ShiftModifier), ("ctrl", Qt.ControlModifier),
                                  ("alt", Qt.AltModifier)) if mods & flag]
        if len(held) != 1:
            return None
        return self.settings.get("keys", {}).get(held[0])

    def _hit(self, p: QPointF):
        dx, dy = p.x() - SIZE / 2, p.y() - SIZE / 2
        r, n = math.hypot(dx, dy), len(self.items)
        if not n or r < INNER or r > OUTER:
            return None
        a = math.atan2(-dy, dx)
        step = 2 * math.pi / n
        i = round(((angle(0, n) - a) % (2 * math.pi)) / step) % n
        diff = abs(math.atan2(math.sin(a - angle(i, n)), math.cos(a - angle(i, n))))
        return i if n == 1 or diff <= step / 2 - math.asin(GAP / 2 / r) else None

    def _set_hover(self, i):
        if i != self.hover:
            self.hover = i
            if i is not None:
                self.play_tick()
            self.update()

    def _choose(self):
        if self.hover is not None and self.items:
            item = self.items[self.hover][0]
            paths, mode = self.paths, self.mode
            self.close_wheel()
            self.chosen.emit(mode, item, paths)
        else:
            self.close_wheel()

    # ---------- drag & drop ----------
    def dragEnterEvent(self, e):
        if not e.mimeData().hasUrls():
            return e.ignore()
        self._leave.stop()
        paths = [u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()]
        if paths != self.paths:
            self.paths, self.items = paths, []
            self._set_mode(self.mode_for_modifiers(e.modifiers()) or self.mode)
        e.setDropAction(Qt.CopyAction)
        e.accept()

    def dragMoveEvent(self, e):
        if m := self.mode_for_modifiers(e.modifiers()):
            self._set_mode(m)
        self._set_hover(self._hit(e.position()))
        e.setDropAction(Qt.CopyAction)
        e.accept()

    def dragLeaveEvent(self, e):
        self._leave.start()

    def dropEvent(self, e):
        self._set_hover(self._hit(e.position()))
        e.setDropAction(Qt.CopyAction)
        e.accept()
        QTimer.singleShot(0, self._choose)  # let Explorer finish DoDragDrop first

    # ---------- mouse & keyboard (hotkey mode) ----------
    def mouseMoveEvent(self, e):
        self._set_hover(self._hit(e.position()))

    def mousePressEvent(self, e):
        self._set_hover(self._hit(e.position()))
        self._choose()

    def keyPressEvent(self, e):
        k, n = e.key(), len(self.items)
        keymode = {Qt.Key_Shift: "shift", Qt.Key_Control: "ctrl", Qt.Key_Alt: "alt"}.get(k)
        if keymode and (m := self.settings.get("keys", {}).get(keymode)):
            self._set_mode(m)
        elif k in (Qt.Key_Right, Qt.Key_Down, Qt.Key_Left, Qt.Key_Up) and n:
            step = 1 if k in (Qt.Key_Right, Qt.Key_Down) else -1
            self._set_hover(((self.hover or 0) + step) % n)
        elif k == Qt.Key_Home and n:
            self._set_hover(0)
        elif k == Qt.Key_End and n:
            self._set_hover(n - 1)
        elif k in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space):
            self._choose()
        elif k in (Qt.Key_Escape, Qt.Key_Tab):
            self.close_wheel()

    def focusOutEvent(self, e):
        if self.keyboard:
            self.close_wheel()

    # ---------- painting ----------
    def _petal(self, i, n) -> QPainterPath:
        c = QPointF(SIZE / 2, SIZE / 2)
        outer = QRectF(c.x() - OUTER, c.y() - OUTER, 2 * OUTER, 2 * OUTER)
        inner = QRectF(c.x() - INNER, c.y() - INNER, 2 * INNER, 2 * INNER)
        p = QPainterPath()
        if n == 1:
            p.addEllipse(outer)
            p.addEllipse(inner)
            return p
        half, a = math.pi / n, angle(i, n)
        go, gi = math.asin(GAP / 2 / OUTER), math.asin(GAP / 2 / INNER)
        s0, s1 = math.degrees(a - half + go), math.degrees(a + half - go)
        p.arcMoveTo(outer, s0)
        p.arcTo(outer, s0, s1 - s0)
        i0, i1 = math.degrees(a + half - gi), math.degrees(a - half + gi)
        p.arcTo(inner, i0, i1 - i0)
        p.closeSubpath()
        return p

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        c = QPointF(SIZE / 2, SIZE / 2)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(28, 28, 30, 215))
        g.drawEllipse(c, OUTER + 8, OUTER + 8)
        n = len(self.items)
        g.setFont(QFont("Segoe UI", 9, QFont.DemiBold))
        for i, (_, title) in enumerate(self.items):
            g.setPen(Qt.NoPen)
            g.setBrush(ORANGE if i == self.hover else QColor(255, 255, 255, 34))
            g.drawPath(self._petal(i, n))
            mid = (INNER + OUTER) / 2
            a = angle(i, n) if n > 1 else math.pi / 2
            pt = QPointF(c.x() + math.cos(a) * mid, c.y() - math.sin(a) * mid)
            w = min(OUTER - INNER, 2 * math.pi * mid / n - 6)
            g.setPen(QColor("white"))
            g.drawText(QRectF(pt.x() - w / 2, pt.y() - 20, w, 40), Qt.AlignCenter | Qt.TextWordWrap, title)
        g.setPen(QColor("white"))
        g.setFont(QFont("Segoe UI", 10, QFont.Bold))
        g.drawText(QRectF(c.x() - INNER, c.y() - 22, 2 * INNER, 22), Qt.AlignCenter, MODE_NAMES[self.mode])
        g.setFont(QFont("Segoe UI", 8))
        count = f"{len(self.paths)} file{'s' * (len(self.paths) != 1)}" if self.paths else "Drop here"
        g.drawText(QRectF(c.x() - INNER, c.y(), 2 * INNER, 20), Qt.AlignCenter, count)
        if not n and self.paths:
            g.drawText(QRectF(c.x() - OUTER, c.y() + INNER, 2 * OUTER, 30), Qt.AlignCenter,
                       f"No {MODE_NAMES[self.mode].lower()} for this selection")
        keys = {v: k for k, v in self.settings.get("keys", {}).items()}
        hint = "    ".join(f"{keys.get(m, '?').capitalize()}: {MODE_NAMES[m]}" for m in MODES)
        if self.hover is not None and n:
            item, title = self.items[self.hover]
            verb = f"make a {title}" if self.mode == "convert" else (
                TOOLS[item][1] if self.mode == "tools" else ACTIONS[item][1]).lower()
            hint = f"{'Press Enter' if self.keyboard else 'Let go'} to {verb}"
        r = QRectF(20, SIZE + 4, SIZE - 40, 26)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(28, 28, 30, 215))
        g.drawRoundedRect(r, 13, 13)
        g.setPen(QPen(QColor("white")))
        g.drawText(r, Qt.AlignCenter, hint)
        g.end()


if __name__ == "__main__":  # quick visual check: python -m pomeloo.ui.wheel FILE
    import sys
    app = QApplication(sys.argv)
    w = Wheel({"keys": {"shift": "convert", "ctrl": "tools", "alt": "actions"}})
    w.chosen.connect(lambda m, i, p: (print(m, i, p), app.quit()))
    w.open_keyboard(QPoint(600, 400), sys.argv[1:] or ["x.png"])
    app.exec()
