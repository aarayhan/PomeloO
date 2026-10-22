"""The drop pad: a small always-on-top target to drop files on, which opens the wheel."""
from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QApplication, QWidget

from .citrus import icon_pixmap as logo


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
