"""Dark-glass design system: palette, app stylesheet, frosted window base, and small custom controls."""
import ctypes
from ctypes import wintypes

from PySide6.QtCore import QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QColorDialog, QDialog, QHBoxLayout, QLabel,
                               QPushButton, QSlider, QVBoxLayout, QWidget)

ACCENT = "#ff8a00"
ACCENT_HOVER = "#ff9f33"
TEXT, MUTED, FAINT = "#f2f2f7", "#a1a1aa", "#6e6e76"
GLASS = QColor(24, 24, 27, 222)     # tint painted over the acrylic blur
BORDER = QColor(255, 255, 255, 26)
RADIUS = 8                           # matches Windows 11's rounded window corners

QSS = f"""
* {{ font-family: 'Segoe UI Variable Text', 'Segoe UI'; font-size: 10pt; color: {TEXT}; }}
QToolTip {{ background: #2a2a2e; color: {TEXT}; border: 1px solid #3a3a40; border-radius: 6px; padding: 4px 8px; }}
QLabel#title {{ font-size: 11pt; font-weight: 700; letter-spacing: 1.5px; }}
QLabel#chip {{ background: rgba(255,255,255,0.08); border-radius: 10px; padding: 2px 10px; color: {MUTED}; }}
QLabel#section {{ color: {FAINT}; font-size: 8pt; font-weight: 700; letter-spacing: 1.2px; }}
QLabel#muted {{ color: {MUTED}; }}
QLabel#value {{ color: {MUTED}; min-width: 44px; }}
QPushButton {{ background: rgba(255,255,255,0.07); border: 1px solid rgba(255,255,255,0.09);
              border-radius: 9px; padding: 6px 14px; }}
QPushButton:hover {{ background: rgba(255,255,255,0.13); }}
QPushButton:pressed {{ background: rgba(255,255,255,0.05); }}
QPushButton:checked {{ background: {ACCENT}; color: #18181b; border-color: {ACCENT}; font-weight: 600; }}
QPushButton#primary {{ background: {ACCENT}; color: #18181b; border: none; border-radius: 16px;
                      padding: 8px 24px; font-weight: 700; }}
QPushButton#primary:hover {{ background: {ACCENT_HOVER}; }}
QPushButton#ghost {{ background: transparent; border: none; color: {MUTED}; padding: 8px 14px; }}
QPushButton#ghost:hover {{ color: {TEXT}; }}
QPushButton#close {{ background: transparent; border: none; color: {MUTED}; font-size: 11pt; padding: 2px 8px; }}
QPushButton#close:hover {{ background: #c42b1c; color: white; }}
QPushButton#seg {{ border-radius: 0; border-left: none; padding: 6px 12px; }}
QPushButton#segFirst {{ border-top-right-radius: 0; border-bottom-right-radius: 0; padding: 6px 12px; }}
QPushButton#segLast {{ border-top-left-radius: 0; border-bottom-left-radius: 0; border-left: none; padding: 6px 12px; }}
QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox {{ background: rgba(255,255,255,0.06);
    border: 1px solid rgba(255,255,255,0.09); border-radius: 8px; padding: 5px 8px;
    selection-background-color: {ACCENT}; selection-color: #18181b; }}
QLineEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {{ border-color: {ACCENT}; }}
QSpinBox::up-button, QSpinBox::down-button, QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{ width: 0; }}
QComboBox::drop-down {{ border: none; width: 18px; }}
QComboBox QAbstractItemView {{ background: #26262a; border: 1px solid #3a3a40; border-radius: 8px;
    selection-background-color: {ACCENT}; selection-color: #18181b; outline: none; padding: 4px; }}
QSlider::groove:horizontal {{ height: 4px; background: rgba(255,255,255,0.14); border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: white; width: 16px; height: 16px; margin: -6px 0; border-radius: 8px; }}
QSlider::handle:horizontal:hover {{ background: #ffe1bf; }}
QSlider#bipolar::sub-page:horizontal {{ background: rgba(255,255,255,0.14); }}
QListWidget, QTableWidget {{ background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08);
    border-radius: 10px; padding: 4px; outline: none; }}
QListWidget::item {{ border-radius: 6px; padding: 4px; }}
QListWidget::item:selected, QTableWidget::item:selected {{ background: rgba(255,138,0,0.35); color: {TEXT}; }}
QHeaderView::section {{ background: transparent; color: {FAINT}; border: none; padding: 4px 6px; font-weight: 600; }}
QTableWidget {{ gridline-color: rgba(255,255,255,0.06); }}
QProgressBar {{ background: rgba(255,255,255,0.09); border: none; border-radius: 2px; max-height: 4px; }}
QProgressBar::chunk {{ background: {ACCENT}; border-radius: 2px; }}
QProgressBar[state="error"]::chunk {{ background: #ff453a; }}
QProgressBar[state="done"]::chunk {{ background: #30d158; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: rgba(255,255,255,0.18); border-radius: 3px; min-height: 24px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar:horizontal {{ background: transparent; height: 8px; margin: 2px; }}
QScrollBar::handle:horizontal {{ background: rgba(255,255,255,0.18); border-radius: 3px; min-width: 24px; }}
QMessageBox, QColorDialog {{ background: #1c1c1f; }}
QMenu {{ background: #232327; border: 1px solid #3a3a40; border-radius: 8px; padding: 4px; }}
QMenu::item {{ padding: 6px 22px 6px 14px; border-radius: 5px; }}
QMenu::item:selected {{ background: rgba(255,138,0,0.85); color: #18181b; }}
QMenu::separator {{ height: 1px; background: #3a3a40; margin: 4px 8px; }}
"""


# ---------- frosted glass (real blur behind the window on Windows 10/11) ----------
class _Accent(ctypes.Structure):
    _fields_ = [("state", ctypes.c_int), ("flags", ctypes.c_int), ("color", ctypes.c_uint), ("anim", ctypes.c_int)]


class _CompositionData(ctypes.Structure):
    _fields_ = [("attr", ctypes.c_int), ("data", ctypes.POINTER(_Accent)), ("size", ctypes.c_size_t)]


def enable_blur(hwnd: int):
    """Acrylic blur behind a frameless window + Windows 11 rounded corners and dark mode. Best effort."""
    try:
        dwm = ctypes.windll.dwmapi
        for attr, value in ((33, 2), (20, 1)):  # DWMWA_WINDOW_CORNER_PREFERENCE=round, IMMERSIVE_DARK_MODE
            v = ctypes.c_int(value)
            dwm.DwmSetWindowAttribute(wintypes.HWND(hwnd), attr, ctypes.byref(v), ctypes.sizeof(v))
        accent = _Accent(4, 2, 0x01000000, 0)  # ACCENT_ENABLE_ACRYLICBLURBEHIND, near-clear tint (we paint ours)
        data = _CompositionData(19, ctypes.pointer(accent), ctypes.sizeof(accent))  # WCA_ACCENT_POLICY
        ctypes.windll.user32.SetWindowCompositionAttribute(wintypes.HWND(hwnd), ctypes.byref(data))
    except Exception:
        pass  # older Windows: the painted tint alone still looks like dark glass


class Header(QWidget):
    """Title · file chip · close. Dragging the header moves the window."""

    def __init__(self, title: str, chip: str = "", on_close=None):
        super().__init__()
        lay = QHBoxLayout(self)
        lay.setContentsMargins(18, 12, 10, 4)
        t = QLabel(title.upper())
        t.setObjectName("title")
        lay.addWidget(t)
        if chip:
            c = QLabel(chip)
            c.setObjectName("chip")
            c.setToolTip(chip)
            lay.addWidget(c)
        lay.addStretch()
        x = QPushButton("✕")
        x.setObjectName("close")
        x.setCursor(Qt.PointingHandCursor)
        x.clicked.connect(on_close or (lambda: self.window().close()))
        lay.addWidget(x)
        self._grab = None

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton:
            self._grab = e.globalPosition().toPoint() - self.window().frameGeometry().topLeft()

    def mouseMoveEvent(self, e):
        if self._grab is not None:
            self.window().move(e.globalPosition().toPoint() - self._grab)

    def mouseReleaseEvent(self, e):
        self._grab = None


class GlassMixin:
    """Frameless, translucent, blurred window with a rounded tinted panel. Call _glass() in __init__."""

    def _glass(self, title, chip="", on_close=None) -> QVBoxLayout:
        self.setWindowFlags(self.windowFlags() | Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        outer.addWidget(Header(title, chip, on_close))
        body = QVBoxLayout()
        body.setContentsMargins(18, 8, 18, 16)
        body.setSpacing(12)
        outer.addLayout(body)
        return body

    def showEvent(self, e):
        enable_blur(int(self.winId()))
        super().showEvent(e)

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        g.setPen(QPen(BORDER, 1))
        g.setBrush(GLASS)
        g.drawRoundedRect(r, RADIUS, RADIUS)
        g.end()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.reject() if isinstance(self, QDialog) else self.close()
        else:
            super().keyPressEvent(e)


def section(text: str) -> QLabel:
    lab = QLabel(text.upper())
    lab.setObjectName("section")
    return lab


def muted(text: str) -> QLabel:
    lab = QLabel(text)
    lab.setObjectName("muted")
    lab.setWordWrap(True)
    return lab


def button(text: str, on_click, primary=False) -> QPushButton:
    b = QPushButton(text)
    b.setCursor(Qt.PointingHandCursor)
    if primary:
        b.setObjectName("primary")
    b.clicked.connect(on_click)
    return b


def footer(primary_text: str, on_primary, on_cancel, cancel_text="Cancel") -> QHBoxLayout:
    row = QHBoxLayout()
    row.addStretch()
    c = QPushButton(cancel_text)
    c.setObjectName("ghost")
    c.clicked.connect(on_cancel)
    p = QPushButton(primary_text)
    p.setObjectName("primary")
    p.setDefault(True)
    p.setCursor(Qt.PointingHandCursor)
    p.clicked.connect(on_primary)
    row.addWidget(c)
    row.addWidget(p)
    return row


# ---------- controls ----------
class Segmented(QWidget):
    """A row of joined toggle buttons for 2-6 choices (replaces small dropdowns)."""
    changed = Signal(object)

    def __init__(self, options, value, labels=None):
        super().__init__()
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.group, self.options = QButtonGroup(self), list(options)
        for i, o in enumerate(self.options):
            b = QPushButton(str((labels or {}).get(o, o)))
            b.setCheckable(True)
            b.setCursor(Qt.PointingHandCursor)
            b.setObjectName("segFirst" if i == 0 else "segLast" if i == len(self.options) - 1 else "seg")
            b.setChecked(o == value)
            self.group.addButton(b, i)
            lay.addWidget(b)
        self.group.idClicked.connect(lambda i: self.changed.emit(self.options[i]))

    def value(self):
        return self.options[max(0, self.group.checkedId())]


class Toggle(QCheckBox):
    """iOS-style switch."""

    def __init__(self, checked=False):
        super().__init__()
        self.setChecked(checked)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedSize(40, 22)

    def hitButton(self, pos):
        return self.rect().contains(pos)

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        on = self.isChecked()
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(ACCENT) if on else QColor(255, 255, 255, 40))
        g.drawRoundedRect(QRectF(0, 0, 40, 22), 11, 11)
        g.setBrush(QColor("white"))
        g.drawEllipse(QRectF(20 if on else 2, 2, 18, 18))
        g.end()


class SliderField(QWidget):
    """Slider with a live value label; scale>1 maps floats onto the integer slider."""
    changed = Signal()

    def __init__(self, lo, hi, value, suffix="", scale=1):
        super().__init__()
        self.scale, self.suffix = scale, suffix
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.s = QSlider(Qt.Horizontal)
        self.s.setRange(int(lo * scale), int(hi * scale))
        self.s.setValue(int(value * scale))
        self.s.setMinimumWidth(170)
        if lo < 0:  # two-way slider: no fill from the left edge
            self.s.setObjectName("bipolar")
        self.s.setCursor(Qt.PointingHandCursor)
        self.lab = QLabel()
        self.lab.setObjectName("value")
        self.lab.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.s.valueChanged.connect(self._update)
        self.default = int(value * scale)
        self.s.mouseDoubleClickEvent = lambda e: self.s.setValue(self.default)  # double-click resets
        lay.addWidget(self.s, 1)
        lay.addWidget(self.lab)
        self._update()

    def _update(self, *_):
        self.lab.setText(f"{self.value():g}{self.suffix}")
        self.changed.emit()

    def value(self):
        v = self.s.value()
        return v / self.scale if self.scale > 1 else v


class Swatch(QPushButton):
    """Round colour button that opens a colour picker."""

    def __init__(self, color: str):
        super().__init__()
        self.setFixedSize(30, 30)
        self.setCursor(Qt.PointingHandCursor)
        self.clicked.connect(self._pick)
        self.set(color)

    def set(self, color):
        self.color = color
        self.setToolTip(color)
        self.setStyleSheet(f"QPushButton{{background:{color};border:2px solid rgba(255,255,255,0.35);"
                           f"border-radius:15px;padding:0}} QPushButton:hover{{border-color:white}}")

    def _pick(self):
        c = QColorDialog.getColor(QColor(self.color), self.window())
        if c.isValid():
            self.set(c.name())
