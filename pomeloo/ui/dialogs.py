"""Tool option dialog (form + visual editors from ui/editors.py), batch progress window, settings."""
import shutil
import tempfile
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QColor, QGuiApplication
from PySide6.QtWidgets import (QApplication, QCheckBox, QColorDialog, QComboBox, QDialog,
                               QDialogButtonBox, QDoubleSpinBox, QFileDialog, QFormLayout, QHBoxLayout,
                               QLabel, QLineEdit, QListWidget, QMessageBox, QPushButton, QSlider, QSpinBox,
                               QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget)

from ..catalog import TOOLS, ext_of, kind
from ..tools import PARAMS, defaults, read_metadata
from .editors import (PREVIEW, FileOrder, MediaScrubber, PagesEditor, ShapeCanvas, fmt_time,
                      pil_to_pixmap, shape_toolbar)

AUDIO_PREVIEW = {"redactAudio", "normalizeAudio", "audioChannels", "trimAudio"}


def preview_image(path: Path):
    """PIL image of a photo, or the middle frame of a video."""
    if kind(ext_of(path)) == "video":
        from ..engines.media import ff, probe
        tmp = Path(tempfile.mkdtemp()) / "frame.png"
        ff("-ss", probe(path)["duration"] / 2, "-i", path, "-frames:v", "1", tmp)
        path = tmp
    from ..engines.image import open_image
    return open_image(path)


class ParamDialog(QDialog):
    def __init__(self, tid: str, paths):
        super().__init__()
        self.tid, self.paths = tid, [Path(p) for p in paths]
        more = f" +{len(paths) - 1}" if len(paths) > 1 else ""
        self.setWindowTitle(f"{TOOLS[tid][1]} - {self.paths[0].name}{more}")
        self.setWindowFlag(Qt.WindowStaysOnTopHint)
        self.getters, self.widgets = {}, {}
        self.canvas = self.scrubber = self.preview = None
        root, self.left, right, form = QHBoxLayout(self), QVBoxLayout(), QVBoxLayout(), QFormLayout()
        for p in PARAMS.get(tid, []):
            w = self._widget(p)
            if w is not None:
                form.addRow(p["label"], w)
                self.widgets[p["key"]] = w
        right.addLayout(form)
        if tid in AUDIO_PREVIEW:
            right.addWidget(self._audio_preview())
        right.addStretch()
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.button(QDialogButtonBox.Ok).setText(TOOLS[tid][1])
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        right.addWidget(bb)
        if self.left.count():
            root.addLayout(self.left)
        root.addLayout(right)
        if self.canvas and isinstance(self.widgets.get("aspect"), QComboBox):  # lock drag to the aspect
            from ..tools.image import ASPECTS
            combo = self.widgets["aspect"]
            combo.currentTextChanged.connect(lambda a: setattr(self.canvas, "aspect", ASPECTS.get(a)))
        self._live()

    # ---------- simple fields ----------
    def _color_button(self, value):
        b = QPushButton(value)
        b.setStyleSheet(f"background:{value}")

        def pick():
            c = QColorDialog.getColor(QColor(b.text()), self)
            if c.isValid():
                b.setText(c.name())
                b.setStyleSheet(f"background:{c.name()}")
        b.clicked.connect(pick)
        return b

    def _widget(self, p):
        t, key, d = p["type"], p["key"], p["default"]
        if t == "int":
            w = QSpinBox(minimum=p.get("min", 0), maximum=p.get("max", 10**9), value=d, suffix=p.get("suffix", ""))
            self.getters[key] = w.value
        elif t == "float":
            w = QDoubleSpinBox(minimum=p.get("min", 0), maximum=p.get("max", 10), value=d, singleStep=0.1)
            self.getters[key] = w.value
        elif t == "slider":  # floats (exposure) are stored x10
            scale = 10 if p["max"] <= 5 else 1
            w, s, lab = QWidget(), QSlider(Qt.Horizontal), QLabel(str(d))
            s.setRange(int(p["min"] * scale), int(p["max"] * scale))
            s.setValue(int(d * scale))
            s.setMinimumWidth(180)
            s.valueChanged.connect(lambda v: (lab.setText(f"{v / scale:g}"), self._live()))
            s.mouseDoubleClickEvent = lambda e, s=s: s.setValue(0)  # double-click resets
            h = QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(s)
            h.addWidget(lab)
            self.getters[key] = (lambda s=s, sc=scale: s.value() / sc) if scale > 1 else s.value
        elif t == "choice":
            w = QComboBox()
            for o in p["options"]:
                w.addItem(str(o), o)
            w.setCurrentIndex(p["options"].index(d))
            w.currentIndexChanged.connect(self._live)
            self.getters[key] = w.currentData
        elif t == "bool":
            w = QCheckBox()
            w.setChecked(d)
            w.toggled.connect(self._live)
            self.getters[key] = w.isChecked
        elif t == "text":
            w = QLineEdit(d)
            self.getters[key] = w.text
        elif t == "color":
            w = self._color_button(d)
            self.getters[key] = w.text
        elif t == "file":
            w, line, b = QWidget(), QLineEdit(d), QPushButton("Browse…")
            b.clicked.connect(lambda: line.setText(QFileDialog.getOpenFileName(
                self, p["label"], "", "Images (*.png *.jpg *.jpeg *.webp *.heic *.bmp *.tiff)")[0] or line.text()))
            h = QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(line)
            h.addWidget(b)
            self.getters[key] = line.text
        elif t == "loudness":
            from ..tools.media import measure_loudness
            m = measure_loudness(self.paths[0])
            w = self.loud_label = QLabel(f"Input {float(m['input_i']):.1f} LUFS, peak {float(m['input_tp']):.1f} dBTP, "
                                         f"range {float(m['input_lra']):.1f} LU")
        else:
            return self._visual(p)
        return w

    # ---------- visual editors (left column) ----------
    def _visual(self, p):
        t, key, d = p["type"], p["key"], p["default"]
        if t == "preview":
            self.thumb = preview_image(self.paths[0])
            self.thumb.thumbnail((PREVIEW, PREVIEW))
            self.preview = QLabel()
            self.preview.setFixedSize(PREVIEW, PREVIEW)
            self.preview.setAlignment(Qt.AlignCenter)
            self.left.addWidget(self.preview)
            self._timer = QTimer(self, singleShot=True, interval=120, timeout=self._render_preview)
        elif t in ("rect", "rects", "shapes"):
            self.canvas = ShapeCanvas(preview_image(self.paths[0]), t)
            hint = {"rect": "Drag to select the region; drag inside it to move. Empty = use Aspect / exact size.",
                    "rects": "Drag to mark regions; drag a region to move it; right-click deletes it.",
                    "shapes": "Pick a tool and draw. Right-click undoes."}[t]
            self.left.addWidget(QLabel(hint))
            if t == "shapes":
                self.left.addWidget(shape_toolbar(self.canvas, self))
                self.getters[key] = lambda: self.canvas.shapes
            elif t == "rect":
                self.getters[key] = lambda: self.canvas.rects[-1] if self.canvas.rects else d
            else:
                self.getters[key] = lambda: self.canvas.rects
            self.left.addWidget(self.canvas)
            if self.tid == "redactImage":
                row = QHBoxLayout()
                for label, faces, text in (("Detect faces", True, False), ("Detect text", False, True)):
                    b = QPushButton(label)
                    b.clicked.connect(lambda _=False, f=faces, x=text: self._detect(f, x))
                    row.addWidget(b)
                self.left.addLayout(row)
        elif t in ("range", "ranges", "times"):
            self.scrubber = MediaScrubber(self.paths[0], t if t != "times" else "times")
            self.left.addWidget(self.scrubber)
            if t == "range":
                self.getters["start"], self.getters["end"] = self.scrubber.start, self.scrubber.end
            elif t == "ranges":
                self.getters[key] = self.scrubber.ranges
            else:
                self.getters[key] = self.scrubber.points
        elif t == "region_times":
            return self._region_times(key)
        elif t == "pages":
            pages = PagesEditor(self.paths[0])
            self.left.addWidget(pages)
            self.getters["order"], self.getters["rotations"] = pages.order, pages.rotations
        elif t == "files":
            if len(self.paths) < 2:
                return None
            lst = FileOrder(self.paths)
            self.getters[key] = lst.paths
            return lst
        elif t == "meta":
            self._meta(key)
        return None

    def _detect(self, faces, text):
        from ..tools.detect import detect
        QGuiApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            found = detect(preview_image(self.paths[0]), faces=faces, text=text)
        finally:
            QGuiApplication.restoreOverrideCursor()
        self.canvas.add_rects(found)
        if not found:
            QMessageBox.information(self, "PomeloO", "Nothing found.")

    def _region_times(self, key):
        """Redact video: give each drawn region its own In/Out range from the scrubber."""
        self.scrubber = MediaScrubber(self.paths[0], "range")
        self.left.addWidget(self.scrubber)
        times: dict[int, list] = {}
        w, idx, lab = QWidget(), QSpinBox(minimum=1, maximum=99, prefix="Region "), QLabel("All regions: whole video")
        apply_, clear = QPushButton("Use In/Out"), QPushButton("Whole video")

        def show():
            lab.setText("; ".join(f"#{i}: {fmt_time(a)}–{fmt_time(b)}" for i, (a, b) in sorted(times.items()))
                        or "All regions: whole video")
        apply_.clicked.connect(lambda: (times.__setitem__(idx.value(), [self.scrubber.start(), self.scrubber.end()]), show()))
        clear.clicked.connect(lambda: (times.pop(idx.value(), None), show()))
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        row = QHBoxLayout()
        for x in (idx, apply_, clear):
            row.addWidget(x)
        lay.addLayout(row)
        lay.addWidget(lab)
        n = lambda: len(self.canvas.rects) if self.canvas else 0
        self.getters[key] = lambda: [times.get(i + 1) for i in range(n())]
        return w

    def _meta(self, key):
        """Grouped (File / Camera / Location / stream N / chapter N) and searchable."""
        table = QTableWidget(0, 3)
        table.setHorizontalHeaderLabels(["Group", "Field", "Value"])
        table.horizontalHeader().setStretchLastSection(True)
        existing = read_metadata(self.paths[0])
        defaults_ = ["File/title", "File/artist", "File/album", "File/author", "File/comment", "File/copyright"]
        for k in dict.fromkeys([*existing, *defaults_]):
            group, _, name = k.rpartition("/")
            r = table.rowCount()
            table.insertRow(r)
            for c, v in enumerate((group or "File", name, str(existing.get(k, "")))):
                it = QTableWidgetItem(v)
                if c < 2:
                    it.setFlags(it.flags() & ~Qt.ItemIsEditable)
                table.setItem(r, c, it)
        table.setMinimumSize(520, 300)
        search = QLineEdit(placeholderText="Search fields…")
        search.textChanged.connect(lambda s: [table.setRowHidden(r, s.lower() not in (
            table.item(r, 0).text() + table.item(r, 1).text() + table.item(r, 2).text()).lower())
            for r in range(table.rowCount())])
        self.left.addWidget(QLabel("Choose 'edit' to write changed fields; 'remove' strips everything "
                                   "(camera, location, processing data)."))
        self.left.addWidget(search)
        self.left.addWidget(table)
        self.getters[key] = lambda: {f"{table.item(r, 0).text()}/{table.item(r, 1).text()}": table.item(r, 2).text()
                                     for r in range(table.rowCount()) if table.item(r, 2).text()}

    # ---------- live preview / audio A-B ----------
    def _live(self, *_):
        if self.preview is not None:
            self._timer.start()

    def _render_preview(self):
        from ..tools.image import apply_edit
        v = {k: g() for k, g in self.getters.items()}
        self.preview.setPixmap(pil_to_pixmap(apply_edit(self.thumb, **v)))

    def _audio_preview(self):
        from PySide6.QtCore import QUrl
        from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
        w = QWidget()
        row = QHBoxLayout(w)
        row.setContentsMargins(0, 0, 0, 0)
        if self.scrubber is None:
            self._player, self._out = QMediaPlayer(self), QAudioOutput(self)
            self._player.setAudioOutput(self._out)
        player = self.scrubber.player if self.scrubber else self._player

        def play(path):
            player.setSource(QUrl.fromLocalFile(str(path)))
            player.play()

        def result():
            from ..tools import run_tool
            QGuiApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                tmp = Path(tempfile.mkdtemp()) / self.paths[0].name
                shutil.copyfile(self.paths[0], tmp)
                out = run_tool(self.tid, [tmp], self.values())[0]
                if self.tid == "normalizeAudio":
                    from ..tools.media import measure_loudness
                    m = measure_loudness(out)
                    self.loud_label.setText(self.loud_label.text().split("  →")[0]
                                            + f"  →  output {float(m['input_i']):.1f} LUFS")
            except Exception as e:
                return QMessageBox.warning(self, "PomeloO", str(e))
            finally:
                QGuiApplication.restoreOverrideCursor()
            play(out)
        for label, fn in (("▶ Original", lambda: play(self.paths[0])), ("▶ Result", result),
                          ("■ Stop", player.stop)):
            b = QPushButton(label)
            b.clicked.connect(fn)
            row.addWidget(b)
        return w

    def values(self) -> dict:
        v = {**defaults(self.tid), **{k: g() for k, g in self.getters.items()}}
        if self.scrubber is not None:
            self.scrubber.player.stop()
        return v

    def done(self, r):
        if self.scrubber is not None:
            self.scrubber.player.stop()
        super().done(r)


# ---------- batch runner ----------
class _Signals(QObject):
    done = Signal(int, object, str)  # row, result, error


class _Job(QRunnable):
    def __init__(self, row, fn, sig):
        super().__init__()
        self.row, self.fn, self.sig = row, fn, sig

    def run(self):
        try:
            self.sig.done.emit(self.row, self.fn(), "")
        except Exception as e:  # surfaced in the window, never swallowed
            self.sig.done.emit(self.row, None, str(e) or e.__class__.__name__)


class ProgressWindow(QWidget):
    """Runs jobs [(label, callable)] in a thread pool, then reveals the results in Explorer."""
    pool = QThreadPool()

    def __init__(self, title, jobs):
        super().__init__(None, Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setWindowTitle(title)
        self.resize(460, min(80 + 26 * len(jobs), 420))
        lay = QVBoxLayout(self)
        self.list = QListWidget()
        lay.addWidget(self.list)
        self.outputs, self.errors, self.left = [], 0, len(jobs)
        self.sig = _Signals()
        self.sig.done.connect(self._done)
        self.pool.setMaxThreadCount(max(2, QThreadPool.globalInstance().maxThreadCount() // 2))
        for i, (label, fn) in enumerate(jobs):
            self.list.addItem(f"⏳  {label}")
            self.pool.start(_Job(i, fn, self.sig))
        self.show()

    def _done(self, row, result, err):
        item = self.list.item(row)
        label = item.text()[3:]
        self.left -= 1
        if err:
            self.errors += 1
            item.setText(f"❌  {label}: {err}")
        else:
            for r in result if isinstance(result, list) else [result]:
                if isinstance(r, str):  # e.g. QR text
                    QApplication.clipboard().setText(r)
                    QMessageBox.information(self, "PomeloO", f"{r}\n\n(copied to clipboard)")
                elif r:
                    self.outputs.append(Path(r))
            item.setText(f"✅  {label}")
        if not self.left:
            if self.outputs:
                from ..actions import reveal
                reveal(self.outputs)  # select in an already-open Explorer window; never open a new one
            if not self.errors:
                QTimer.singleShot(1200, self.close)


# ---------- settings ----------
class SettingsDialog(QDialog):
    def __init__(self, settings: dict):
        super().__init__()
        self.setWindowTitle("PomeloO Settings")
        self.s = settings
        form = QFormLayout(self)
        self.combos = {}
        rev = {v: k for k, v in settings["keys"].items()}
        for mode in ("convert", "tools", "actions"):
            c = QComboBox()
            c.addItems(["shift", "ctrl", "alt"])
            c.setCurrentText(rev.get(mode, "shift"))
            self.combos[mode] = c
            form.addRow(f"{mode.capitalize()} wheel key", c)
        self.hotkey = QLineEdit(settings["hotkey"])
        form.addRow("Wheel hotkey (Explorer selection)", self.hotkey)
        self.checks = {}
        for k, label in (("drag_wheel", "Show wheel when tapping a key while dragging in Explorer"),
                         ("show_pad", "Show floating drop pad"), ("sound", "Highlight sound"),
                         ("fix_whatsapp_overlay", "Fix WhatsApp's invisible layer blocking desktop right-click")):
            cb = QCheckBox(label)
            cb.setChecked(settings[k])
            self.checks[k] = cb
            form.addRow(cb)
        bb = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)

    def result_settings(self) -> dict | None:
        keys = {c.currentText(): m for m, c in self.combos.items()}
        if len(keys) != 3:
            QMessageBox.warning(self, "PomeloO", "Each wheel needs a different key.")
            return None
        return {**self.s, "keys": keys, "hotkey": self.hotkey.text().strip().lower(),
                **{k: cb.isChecked() for k, cb in self.checks.items()}}
