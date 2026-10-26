"""The notch: a black pill at the top of the screen. Hover opens a small panel (Jobs, Shelf, Clipboard,
Recent, Phone); dragging files to the top turns it into drop zones; short notices and suggestions
(new downloads, a copied screenshot) slide out of it. It hides while a full-screen app, game or
presentation runs, and screen capture / screen sharing never sees it."""
import ctypes
from functools import partial

from PySide6.QtCore import QEasingCurve, QPropertyAnimation, QRect, QRectF, Qt, QTimer
from PySide6.QtGui import QColor, QCursor, QGuiApplication, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QHBoxLayout, QLabel, QLayout, QStackedLayout, QStackedWidget, QVBoxLayout, QWidget

from .notch_tabs import ClipTab, JobsTab, PhoneTab, RecentTab, ShelfTab
from .theme import ACCENT, button, muted

SIZES = {"pill": (180, 28), "toast": (460, 36), "suggest": (600, 46), "panel": (680, 300), "drop": (720, 112)}
# Settings → Notch → Size: Small. Only the parts that sit on screen shrink; the panel and drop zones keep their room
SMALL = {"pill": (124, 20), "toast": (380, 30), "suggest": (500, 38)}
_CHIP = ("QLabel{background:rgba(255,255,255,0.07);border:1px solid rgba(255,255,255,0.10);border-radius:10px;"
         "padding:0 12px;color:#f4f4f5}")
_HOT = ("QLabel{background:%s;border:1px solid %s;border-radius:10px;padding:0 12px;color:#18181b}"
        % (ACCENT, ACCENT))
_TAB = ("QPushButton{background:transparent;border:none;border-bottom:2px solid transparent;color:#a1a1aa;"
        "padding:4px 10px;border-radius:0} QPushButton:checked{color:#f4f4f5;border-bottom:2px solid %s}" % ACCENT)
_PREFERRED = ["jpg", "png", "webp", "pdf", "mp4", "mp3", "docx", "gif", "xlsx", "zip"]


class Notch(QWidget):
    def __init__(self, app):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool | Qt.WindowDoesNotAcceptFocus)
        self.app, self.s = app, app.settings
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setAcceptDrops(True)
        self.state, self.quiet, self.drop_paths, self.made = "pill", False, None, set()
        self.tracked, self.pending_downloads = [], []  # running batches; downloads seen meanwhile
        self.anim = QPropertyAnimation(self, b"geometry", duration=180, easingCurve=QEasingCurve.OutCubic)
        self.anim.finished.connect(lambda: self._settle())
        # 300 ms: passing over the pill on the way to a browser tab or title bar doesn't open it; a click does
        self.hover_timer = QTimer(self, singleShot=True, interval=300, timeout=lambda: self.go("panel"))
        self.back_timer = QTimer(self, singleShot=True, timeout=self.collapse)

        self.pages = QStackedLayout(self)
        self.pages.setSizeConstraint(QLayout.SetNoConstraint)  # the notch sets its own size per state
        self.pill = QLabel(alignment=Qt.AlignCenter)
        self.pill.setStyleSheet("color:#a1a1aa;font-size:11px")
        self.toast_label = QLabel(alignment=Qt.AlignCenter)
        self.toast_label.setStyleSheet("color:#f4f4f5;font-weight:600")
        self.suggest_box, self.drop_box = QWidget(), QWidget()
        self.panel = self._build_panel()
        self.page = {"pill": self.pill, "toast": self.toast_label, "suggest": self.suggest_box,
                     "panel": self.panel, "drop": self.drop_box}
        for w in self.page.values():
            self.pages.addWidget(w)
        self.shelf.changed.connect(self._pill_text)
        self.phone.stopped.connect(self.collapse_now)  # Stop (or the idle limit) also closes the notch
        self.clip.image_copied.connect(self._copied_image)
        from ..recipes import NewFiles
        self.downloads = NewFiles(self._downloaded)
        self.apply_settings()
        self.setGeometry(self._rect("pill"))
        self._pill_text()
        self.show()

    # ---------- layout ----------
    def _build_panel(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(18, 10, 18, 12)
        head = QHBoxLayout()
        self.tabs = QStackedWidget()
        self.jobs, self.shelf, self.clip, self.recent, self.phone = JobsTab(), ShelfTab(), ClipTab(), RecentTab(), PhoneTab()
        self.tab_of = {"Jobs": self.jobs, "Shelf": self.shelf, "Clipboard": self.clip, "Recent": self.recent,
                       "Phone": self.phone}
        self.tab_buttons = {}
        for name, tab in self.tab_of.items():
            self.tabs.addWidget(tab)
            b = button(name, partial(self.show_tab, name))
            b.setCheckable(True)
            b.setStyleSheet(_TAB)
            self.tab_buttons[name] = b
            head.addWidget(b)
        head.addStretch()
        head.addWidget(button("Copy text from screen", self._screen_text))
        lay.addLayout(head)
        lay.addWidget(self.tabs, 1)
        self.show_tab("Shelf")
        return w

    def show_tab(self, name):
        if name != "Phone":
            self.phone.stop()  # sharing lives only while its QR is on screen
        self.tabs.setCurrentWidget(self.tab_of[name])
        for n, b in self.tab_buttons.items():
            b.setChecked(n == name)
        if name == "Recent":
            self.recent.refresh()

    def small(self) -> bool:
        return self.s.get("notch_size") == "small"

    def apply_settings(self):
        self.pill.setStyleSheet(f"color:#a1a1aa;font-size:{9 if self.small() else 11}px")
        self.toast_label.setStyleSheet(f"color:#f4f4f5;font-weight:600;font-size:{9 if self.small() else 10}pt")
        for name, key in (("Clipboard", "notch_clipboard"), ("Recent", "notch_recent"), ("Phone", "notch_phone")):
            self.tab_buttons[name].setVisible(self.s.get(key, True))
        from PySide6.QtCore import QStandardPaths
        downloads = QStandardPaths.writableLocation(QStandardPaths.DownloadLocation)
        self.downloads.set_folders([downloads] if self.s.get("notch_downloads", True) else [])
        self.setGeometry(self._rect(self.state))

    def _screen(self):
        if self.s.get("notch_screen") == "cursor":
            return QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        return QGuiApplication.primaryScreen()

    def _rect(self, state) -> QRect:
        w, h = (self.small() and SMALL.get(state)) or SIZES[state]
        g = self._screen().availableGeometry()
        # right: stay clear of maximized windows' minimize / maximize / close buttons (~140 px)
        x = {"left": g.left() + 24, "right": g.right() - w - 170}.get(self.s.get("notch_position"), g.center().x() - w // 2)
        return QRect(x, g.top(), w, h)

    def go(self, state):
        """Switch look (pill / toast / suggest / panel / drop) with a short slide; none on battery saver."""
        from ..notchcore import battery_saver
        self.state = state
        target = self._rect(state)
        self.anim.stop()
        if battery_saver():
            # page first: shrinking while the big panel page is still current leaves the window stuck at the
            # panel's minimum size (a blank black box)
            self._settle()
            self.setGeometry(target)
            return
        # growing: the bigger page goes in once the slide is done (mid-slide frames are smaller than it);
        # shrinking: the smaller page goes in first
        self.pages.setCurrentWidget(self.page[state] if target.height() <= self.height() else self.pill)
        self.anim.setStartValue(self.geometry())
        self.anim.setEndValue(target)
        self.anim.start()
        self.update()

    def _settle(self):
        self.pages.setCurrentWidget(self.page[self.state])
        self.update()

    def collapse(self):
        if self.underMouse() or (self.phone.active() and self.state == "panel"):
            return self.back_timer.start(800)  # stay open while used, or while the phone QR is up
        self.collapse_now()

    def collapse_now(self):
        self.back_timer.stop()
        self.phone.stop()  # the QR is going away, so is the sharing
        self._pill_text()
        self.go("pill")

    def _fresh(self, name) -> QWidget:
        """A new, empty page in place of the old one (simplest way to rebuild it)."""
        old, new = self.page[name], QWidget()
        self.pages.insertWidget(self.pages.indexOf(old), new)
        self.pages.removeWidget(old)
        old.deleteLater()
        self.page[name] = new
        return new

    # ---------- look ----------
    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0, -0.5, -0.5)
        radius = 14 if self.state in ("pill", "toast") else 22
        path = QPainterPath()
        path.addRoundedRect(r.adjusted(0, -radius, 0, 0), radius, radius)  # square top: it hangs from the edge
        g.fillPath(path, QColor(8, 8, 9, 250))
        g.setPen(QPen(QColor(255, 255, 255, 22), 1))
        g.drawPath(path)
        if self.state == "pill" and self.jobs.running():  # thin progress line under the pill
            frac = max((b.fraction for b in self.jobs.batches if b.left), default=0)
            g.setPen(QPen(QColor(ACCENT), 2, Qt.SolidLine, Qt.RoundCap))
            g.drawLine(14, self.height() - 3, 14 + int((self.width() - 28) * frac), self.height() - 3)
        g.end()

    def _pill_text(self):
        bits = []
        if self.jobs.running():
            bits.append(f"Working… {int(100 * max(b.fraction for b in self.jobs.batches if b.left))}%")
        if n := self.shelf.count():
            bits.append(f"{n} on shelf")
        self.pill.setText("  ·  ".join(bits))
        self.update()

    def showEvent(self, e):
        # screenshots, recordings and screen sharing (Zoom, Meet, Teams...) skip this window entirely
        ctypes.windll.user32.SetWindowDisplayAffinity(int(self.winId()), 0x11)  # WDA_EXCLUDEFROMCAPTURE
        super().showEvent(e)

    def set_quiet(self, quiet: bool):
        """A full-screen app, game or presentation is in front: step aside."""
        self.quiet = quiet
        self.setVisible(not quiet)

    # ---------- hover ----------
    def enterEvent(self, e):
        self.back_timer.stop()
        if self.state in ("pill", "toast"):
            self.hover_timer.start()

    def leaveEvent(self, e):
        self.hover_timer.stop()
        if self.state in ("panel", "drop"):
            self.back_timer.start(450)
        elif self.state in ("toast", "suggest"):
            self.back_timer.start(2500)  # it was paused while the mouse was over it

    def mousePressEvent(self, e):
        if self.state in ("pill", "toast"):
            self.hover_timer.stop()
            self.go("panel")

    # ---------- notices and suggestions ----------
    def toast(self, text, ms=3500) -> bool:
        """False when not shown (the panel is in use): callers then use the tray instead."""
        if self.state == "panel" and (self.underMouse() or self.phone.active()):
            return False  # don't yank the panel away from someone using it (or from the phone's QR)
        self.toast_label.setText(text)
        self.go("toast")
        self.back_timer.start(ms)
        return True

    def suggest(self, text, steps, ms=9000):
        """steps: [(label, callable)], shown as a strip of buttons that goes away by itself."""
        if self.state in ("panel", "drop") and (self.underMouse() or self.phone.active()):
            return
        lay = QHBoxLayout(self._fresh("suggest"))
        lay.setContentsMargins(*((14, 3, 8, 4) if self.small() else (18, 4, 10, 6)))
        lay.addWidget(QLabel(text, styleSheet="color:#f4f4f5" + (";font-size:9pt" if self.small() else "")), 1)
        tight = "font-size:9pt;padding:2px 10px;min-height:0" if self.small() else ""
        for lab, fn in steps + [("×", self.collapse_now)]:
            b = button(lab, partial(self._run_and_close, fn) if lab != "×" else fn)
            b.setStyleSheet(tight)
            lay.addWidget(b)
        self.go("suggest")
        self.back_timer.start(ms)

    def _run_and_close(self, fn):
        self.collapse_now()
        fn()

    def _downloaded(self, path, folder):
        """A new file in Downloads. While PomeloO jobs run, decide later: the file may be one of their
        results (or a temp file) that only becomes known when the job ends."""
        if any(b.left for b in self.tracked):
            self.pending_downloads.append(path)
            return
        from ..notchcore import label, suggestions
        mine = self.made | {str(o) for b in self.tracked for o in b.outputs}
        if str(path) in mine or not path.exists() or not (steps := suggestions(path)):
            return
        self.suggest(f"⬇  {path.name}", [(label(s), partial(self.run_step, s, [str(path)])) for s in steps])

    def _jobs_settled(self):
        self.made |= {str(o) for b in self.tracked for o in b.outputs}
        self.tracked = [b for b in self.tracked if b.left]
        if not self.tracked:
            pending, self.pending_downloads = self.pending_downloads, []
            for p in pending[-1:]:  # one suggestion is plenty
                self._downloaded(p, p.parent)

    def _copied_image(self, img):
        if not self.s.get("notch_screenshots", True):
            return
        save = lambda: ClipTab.save(img, "Screenshot")  # noqa: E731
        self.suggest("📋  Image copied", [
            ("Save as file", lambda: self.app.reveal_new(save())),
            ("Copy text", lambda: self.app.screen_text.read(img)),
            ("Annotate", lambda: self.app.dispatch("tool", "annotateImage", [str(save())])),
            ("To phone", lambda: self.open_phone([str(save())]))])

    def run_step(self, step, paths):
        kind, ident = step
        if kind == "fit":
            self.app.run_fit(ident, paths)
        else:
            self.app.dispatch(kind, ident, paths)

    # ---------- jobs, phone, shelf ----------
    def track(self, batch, show_progress: bool):
        """Every batch: its results never trigger a Downloads suggestion. With notch progress on, it is
        shown in the Jobs tab and the pill, and ends with a short notice."""
        self.tracked.append(batch)
        batch.finished.connect(self._jobs_settled)
        if not show_progress:
            return
        self.jobs.add(batch)
        batch.changed.connect(self._pill_text)

        def done():
            text = batch.text()
            msg = (f"Copied · {len(text.split())} words" if text else
                   " · ".join(x for x in (f"{batch.title}: {batch.status()}", batch.savings()) if x))
            self.recent.refresh()
            self.toast(msg, 6000 if batch.failures else 3500)
        batch.finished.connect(done)
        self._pill_text()

    def open_phone(self, files=()):
        try:
            self.phone.start([str(f) for f in files])
        except (RuntimeError, OSError) as e:
            return self.toast(str(e), 6000)
        self.show_tab("Phone")
        self.go("panel")

    def add_to_shelf(self, paths):
        self.shelf.add(paths)
        n = self.shelf.count()
        self.toast(f"On the shelf · {n} file{'s' * (n != 1)}")

    def _screen_text(self):
        self.collapse_now()
        QTimer.singleShot(200, self.app.screen_text.trigger)  # let the panel get out of the screenshot

    # ---------- drop zones ----------
    def open_drop(self):
        """A file dragged from Explorer reached the top of the screen (native EV_DRAG_TOP)."""
        if not self.quiet:
            self._build_drop([])
            self.go("drop")
            self.back_timer.start(2500)  # closes again if the drag goes elsewhere

    def _build_drop(self, paths):
        from ..catalog import selection_ext, targets
        from ..notchcore import FIT, fits
        from ..recipes import PREFIX, applies
        self.drop_paths = paths
        outer = QVBoxLayout(self._fresh("drop"))
        outer.setContentsMargins(18, 10, 18, 12)
        outer.setSpacing(6)
        ext = selection_ext(paths) if paths else None
        rows = [[], []]
        if ext:
            fmts = sorted(targets(ext), key=lambda f: _PREFERRED.index(f) if f in _PREFERRED else 99)[:5]
            rows[0] += [(f.upper(), partial(self.app.dispatch, "convert", f)) for f in fmts]
            rows[0] += [("Tools…", partial(self._wheel, "tools")), ("Actions…", partial(self._wheel, "actions"))]
        rows[1] += [("Shelf", self.add_to_shelf), ("Phone", self.open_phone)]
        if ext:
            rows[1] += [(f"Fit {FIT[p]}", partial(self.app.run_fit, p)) for p in FIT if fits(ext, p)]
            rows[1] += [("★ " + r["name"], partial(self.app.dispatch, "tool", PREFIX + r["name"]))
                        for r in self.s.get("recipes", []) if applies(r, ext)]
        if not paths:
            outer.addWidget(muted("Drop here: convert, keep on the shelf, send to your phone, shrink for WhatsApp…"))
        for row in rows:
            h = QHBoxLayout()
            h.setSpacing(6)
            for text, fn in row:
                chip = QLabel(text, alignment=Qt.AlignCenter)
                chip.setFixedHeight(34)
                chip.setStyleSheet(_CHIP)
                chip.setProperty("zone", fn)
                h.addWidget(chip)
            h.addStretch()
            outer.addLayout(h)

    def _wheel(self, mode, paths):
        self.app.wheel.open_keyboard(QCursor.pos(), paths, mode)

    def _zone_at(self, pos):
        w = self.childAt(pos)
        while w is not None and w.property("zone") is None:
            w = w.parentWidget()
        return w

    def dragEnterEvent(self, e):
        if not e.mimeData().hasUrls() or (e.source() is not None and self.isAncestorOf(e.source())):
            e.ignore()  # e.g. a file being dragged out of the shelf
            return
        paths = [u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()]
        if paths != self.drop_paths or self.state != "drop":
            self._build_drop(paths)
            self.go("drop")
        self.back_timer.stop()
        e.acceptProposedAction()

    def dragMoveEvent(self, e):
        hot = self._zone_at(e.position().toPoint())
        for chip in self.page["drop"].findChildren(QLabel):
            if chip.property("zone") is not None:
                chip.setStyleSheet(_HOT if chip is hot else _CHIP)
        e.acceptProposedAction()

    def dragLeaveEvent(self, e):
        self.back_timer.start(600)

    def dropEvent(self, e):
        zone = self._zone_at(e.position().toPoint())
        paths = [u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()]
        e.acceptProposedAction()
        self.drop_paths = None
        self.collapse_now()
        if zone is not None and paths:
            zone.property("zone")(paths)
        elif paths:  # dropped on the notch but not on a zone: keep them on the shelf
            self.add_to_shelf(paths)
