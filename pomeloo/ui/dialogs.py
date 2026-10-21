"""Tool option dialog: dark-glass window, visual editors on the left, friendly controls on the right."""
import shutil
import tempfile
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import (QComboBox, QDialog, QFileDialog, QHBoxLayout, QLabel, QLineEdit, QPushButton,
                               QSpinBox, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget)

from ..catalog import TOOLS, ext_of, kind
from ..tools import PARAMS, defaults, read_metadata
from .editors import (PREVIEW, FileOrder, MediaScrubber, PagesEditor, ShapeCanvas, fmt_time,
                      pil_to_pixmap, shape_toolbar)
from .theme import GlassMixin, Segmented, SliderField, Swatch, Toggle, footer, muted, section

AUDIO_PREVIEW = {"redactAudio", "normalizeAudio", "audioChannels", "trimAudio"}
# Friendlier labels for choice values
LABELS = {"channels": {1: "Mono", 2: "Stereo"}, "factor": {f: f"{f:g}×" for f in (0.25, 0.5, 0.75, 1.5, 2.0, 4.0)},
          "rotate": {r: f"{r}°" for r in (0, 90, 180, 270)}}
SLIDER_SUFFIXES = (" %", " LUFS", "°")


def preview_image(path: Path):
    """PIL image of a photo, or the middle frame of a video."""
    if kind(ext_of(path)) == "video":
        from ..engines.media import ff, probe
        tmp = Path(tempfile.mkdtemp()) / "frame.png"
        ff("-ss", probe(path)["duration"] / 2, "-i", path, "-frames:v", "1", tmp)
        path = tmp
    from ..engines.image import open_image
    return open_image(path)


def _pretty(v) -> str:
    return str(v).replace("_", " ").capitalize() if isinstance(v, str) else str(v)


def _size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


class ParamDialog(GlassMixin, QDialog):
    def __init__(self, tid: str, paths):
        super().__init__()
        self.tid, self.paths = tid, [Path(p) for p in paths]
        chip = self.paths[0].name + (f"  +{len(paths) - 1}" if len(paths) > 1 else "")
        self.setWindowTitle(f"{TOOLS[tid][1]} - {chip}")
        self.setWindowFlag(Qt.WindowStaysOnTopHint)
        body = self._glass(TOOLS[tid][1], chip, self.reject)
        self.getters, self.widgets, self.fields = {}, {}, {}
        self.canvas = self.scrubber = self.preview = self.info = None
        content, self.left, self.right = QHBoxLayout(), QVBoxLayout(), QVBoxLayout()
        content.setSpacing(20)
        self.left.setSpacing(8)
        self.right.setSpacing(6)
        for p in PARAMS.get(tid, []):
            self._add(p)
        if tid in AUDIO_PREVIEW:
            self.right.addSpacing(6)
            self.right.addWidget(section("Preview"))
            self.right.addWidget(self._audio_preview())
        if tid == "compress":
            self.info = muted("")
            self.right.addSpacing(4)
            self.right.addWidget(self.info)
        self.right.addStretch()
        if self.left.count():
            content.addLayout(self.left)
        side = QWidget()
        side.setLayout(self.right)
        side.setMinimumWidth(320)
        content.addWidget(side)
        body.addLayout(content)
        body.addLayout(footer(TOOLS[tid][1], self.accept, self.reject))
        if self.canvas and isinstance(self.widgets.get("aspect"), Segmented):  # lock drag to the aspect
            from ..tools.image import ASPECTS
            self.widgets["aspect"].changed.connect(lambda a: setattr(self.canvas, "aspect", ASPECTS.get(a)))
        for src in {p["show_if"][0] for p in PARAMS.get(tid, []) if "show_if" in p}:
            if isinstance(self.widgets.get(src), Segmented):
                self.widgets[src].changed.connect(self._visibility)
        self._visibility()
        self._live()

    def _visibility(self, *_):
        """Show options only while they matter (e.g. Color only for the Color style)."""
        for p in PARAMS.get(self.tid, []):
            if "show_if" in p and p["key"] in self.fields:
                src, values = p["show_if"]
                self.fields[p["key"]].setVisible(src in self.getters and self.getters[src]() in values)
        self.adjustSize()

    # ---------- right column: one labelled control per param ----------
    def _add(self, p):
        w = self._widget(p)
        if w is None:
            return
        self.widgets[p["key"]] = w
        field = QWidget()
        if p["type"] in ("slider", "bool"):  # compact single row: label | control
            lay = QHBoxLayout(field)
            lab = QLabel(p["label"])
            lab.setMinimumWidth(118 if p["type"] == "slider" else 0)
            lay.addWidget(lab)
            if p["type"] == "bool":
                lay.addStretch()
            lay.addWidget(w, 1 if p["type"] == "slider" else 0)
        else:
            lay = QVBoxLayout(field)
            lay.setSpacing(6)
            lay.addWidget(section(p["label"]))
            lay.addWidget(w)
            lay.setContentsMargins(0, 4, 0, 0)
        if p["type"] in ("slider", "bool"):
            lay.setContentsMargins(0, 0, 0, 0)
        self.fields[p["key"]] = field
        self.right.addWidget(field)

    def _widget(self, p):
        t, key, d = p["type"], p["key"], p["default"]
        if t == "slider":  # floats (exposure) are stored x10
            scale = 10 if p["max"] <= 5 else 1
            w = SliderField(p["min"], p["max"], d, scale=scale)
            w.changed.connect(self._live)
            self.getters[key] = w.value
        elif t in ("int", "float") and (p.get("suffix") in SLIDER_SUFFIXES or t == "float"):
            w = SliderField(p.get("min", 0), p.get("max", 100), d, p.get("suffix", ""),
                            scale=10 if t == "float" else 1)
            w.changed.connect(self._live)
            self.getters[key] = w.value
        elif t == "int":
            w = QSpinBox(minimum=p.get("min", 0), maximum=p.get("max", 10**9), value=d, suffix=p.get("suffix", ""))
            w.setSpecialValueText("Auto" if d == 0 and p.get("min", 0) == 0 else "")
            w.valueChanged.connect(self._live)
            self.getters[key] = w.value
        elif t == "choice":
            opts = p["options"]
            labels = LABELS.get(key, {o: _pretty(o) for o in opts})
            if len(opts) <= 6:
                w = Segmented(opts, d, labels)
                w.changed.connect(self._live)
                self.getters[key] = w.value
            else:
                w = QComboBox()
                for o in opts:
                    w.addItem(labels.get(o, str(o)), o)
                w.setCurrentIndex(opts.index(d))
                w.currentIndexChanged.connect(self._live)
                self.getters[key] = w.currentData
        elif t == "bool":
            w = Toggle(d)
            w.toggled.connect(self._live)
            self.getters[key] = w.isChecked
        elif t in ("text", "password"):
            w = QLineEdit(d)
            if t == "password":
                w.setEchoMode(QLineEdit.Password)
                w.setPlaceholderText("Type it here")
            else:
                w.setPlaceholderText("Every page")
            self.getters[key] = w.text
        elif t == "color":
            w = Swatch(d)
            self.getters[key] = lambda w=w: w.color
        elif t == "file":
            filt = p.get("filter", "Images (*.png *.jpg *.jpeg *.webp *.heic *.bmp *.tiff)")
            w, chosen = QPushButton(f"Choose {filt.split()[0].lower().rstrip('s')}…"), {"path": d}
            w.setCursor(Qt.PointingHandCursor)
            if p.get("hint"):
                w.setToolTip(p["hint"])

            def pick():
                f = QFileDialog.getOpenFileName(self, p["label"], "", filt)[0]
                if f:
                    chosen["path"] = f
                    w.setText(Path(f).name)
            w.clicked.connect(pick)
            self.getters[key] = lambda: chosen["path"]
        elif t == "loudness":
            from ..tools.media import measure_loudness
            m = measure_loudness(self.paths[0])
            w = self.loud_label = muted(f"Now {float(m['input_i']):.1f} LUFS · peak {float(m['input_tp']):.1f} dBTP · "
                                        f"range {float(m['input_lra']):.1f} LU")
        else:
            return self._visual(p)
        return w

    # ---------- left column: visual editors ----------
    def _visual(self, p):
        t, key, d = p["type"], p["key"], p["default"]
        if t == "preview":
            self.thumb = preview_image(self.paths[0])
            self.thumb.thumbnail((PREVIEW, PREVIEW))
            self.preview = QLabel()
            self.preview.setFixedSize(PREVIEW, PREVIEW)
            self.preview.setAlignment(Qt.AlignCenter)
            self.left.addWidget(self.preview)
            self.left.addWidget(muted("Double-click a slider to reset it."))
            self._timer = QTimer(self, singleShot=True, interval=90, timeout=self._render_preview)
        elif t in ("rect", "rects", "shapes"):
            self.canvas = ShapeCanvas(preview_image(self.paths[0]), t)
            hint = {"rect": "Drag to choose the area · drag inside it to move · leave empty to use the aspect below",
                    "rects": "Drag to cover an area · drag it to move · right-click removes it",
                    "shapes": "Pick a tool and draw on the photo · right-click undoes"}[t]
            if t == "shapes":
                self.left.addWidget(shape_toolbar(self.canvas, self))
                self.getters[key] = lambda: self.canvas.shapes
            elif t == "rect":
                self.getters[key] = lambda: self.canvas.rects[-1] if self.canvas.rects else d
            else:
                self.getters[key] = lambda: self.canvas.rects
            self.left.addWidget(self.canvas)
            self.left.addWidget(muted(hint))
            if self.tid == "redactImage":
                row = QHBoxLayout()
                for label, faces, text in (("Find faces", True, False), ("Find text", False, True)):
                    b = QPushButton(label)
                    b.setCursor(Qt.PointingHandCursor)
                    b.clicked.connect(lambda _=False, f=faces, x=text: self._detect(f, x))
                    row.addWidget(b)
                row.addStretch()
                self.left.addLayout(row)
        elif t in ("range", "ranges", "times"):
            self.scrubber = MediaScrubber(self.paths[0], t)
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
        from .windows import notice
        QGuiApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            found = detect(preview_image(self.paths[0]), faces=faces, text=text)
        finally:
            QGuiApplication.restoreOverrideCursor()
        self.canvas.add_rects(found)
        if not found:
            notice(self, "Nothing found", f"No {'faces' if faces else 'text'} detected in this photo.")

    def _region_times(self, key):
        """Redact video: give each drawn area its own In/Out range from the player."""
        self.scrubber = MediaScrubber(self.paths[0], "range")
        self.left.addWidget(self.scrubber)
        times: dict[int, list] = {}
        w, idx, lab = QWidget(), QSpinBox(minimum=1, maximum=99, prefix="Area "), muted("Every area covers the whole video")
        apply_, clear = QPushButton("Use In → Out"), QPushButton("Whole video")

        def show():
            lab.setText("  ·  ".join(f"Area {i}: {fmt_time(a)} → {fmt_time(b)}" for i, (a, b) in sorted(times.items()))
                        or "Every area covers the whole video")
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
        table.verticalHeader().setVisible(False)
        table.setShowGrid(False)
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
        self.left.addWidget(search)
        self.left.addWidget(table)
        self.left.addWidget(muted("Edit writes the changed fields · Remove strips everything, "
                                  "including camera, location and editing data."))
        self.getters[key] = lambda: {f"{table.item(r, 0).text()}/{table.item(r, 1).text()}": table.item(r, 2).text()
                                     for r in range(table.rowCount()) if table.item(r, 2).text()}

    # ---------- live preview / estimates / audio A-B ----------
    def _live(self, *_):
        if self.preview is not None:
            self._timer.start()
        if self.info is not None and "percent" in self.getters:
            total = sum(p.stat().st_size for p in self.paths)
            kb = self.getters["target_kb"]()
            preset = self.getters["preset"]()
            from ..tools import PRESETS
            pct = PRESETS.get(preset, self.getters["percent"]())
            target = kb * 1024 * len(self.paths) if kb else total * pct / 100
            self.info.setText(f"{_size(total)}  →  about {_size(target)}")

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
            from .windows import notice
            QGuiApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                tmp = Path(tempfile.mkdtemp()) / self.paths[0].name
                shutil.copyfile(self.paths[0], tmp)
                out = run_tool(self.tid, [tmp], self.values())[0]
                if self.tid == "normalizeAudio":
                    from ..tools.media import measure_loudness
                    m = measure_loudness(out)
                    self.loud_label.setText(self.loud_label.text().split("  →")[0]
                                            + f"  →  after {float(m['input_i']):.1f} LUFS")
            except Exception as e:
                return notice(self, "Preview failed", str(e))
            finally:
                QGuiApplication.restoreOverrideCursor()
            play(out)
        for label, fn in (("▶  Original", lambda: play(self.paths[0])), ("▶  Result", result), ("■", player.stop)):
            b = QPushButton(label)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(fn)
            row.addWidget(b)
        return w

    def values(self) -> dict:
        v = {**defaults(self.tid), **{k: g() for k, g in self.getters.items()}}
        if self.scrubber is not None:
            self.scrubber.player.stop()
        return v

    def accept(self):
        g = self.getters
        if "rects" in g and not g["rects"]() and g.get("auto", lambda: "none")() == "none":
            from .windows import notice
            return notice(self, "Nothing to redact", "Drag over the area to hide first."
                          + (" Or pick Auto-detect / Find faces." if "auto" in g else ""))
        super().accept()

    def done(self, r):
        from PySide6.QtCore import QUrl
        for p in (getattr(self.scrubber, "player", None), getattr(self, "_player", None)):
            if p is not None:
                p.stop()
                p.setSource(QUrl())
        super().done(r)
        # Lambdas on child-widget signals capture self, so the dialog sits in a reference cycle and
        # Python's GC would free it at a random moment, e.g. mid-batch: that crashed the app. Delete
        # it from the event loop instead (values() is read before control gets back there).
        self.deleteLater()
