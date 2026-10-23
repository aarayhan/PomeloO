"""Render PomeloO's windows to PNG for the website (pomeloo-website/public/screens), at 2x.

Widgets are grabbed directly: the notch hides itself from screen capture, so a normal screenshot
would miss it. Real-looking inputs come from a samples folder (photo.jpg, clip.mp4, document.pdf...).

    python scripts/screenshots.py OUT_DIR [SAMPLES_DIR]
"""
import os
import shutil
import sys
import tempfile
import time
from functools import partial
from pathlib import Path

os.environ.setdefault("QT_SCALE_FACTOR", "2")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from PySide6.QtCore import QPoint  # noqa: E402
from PySide6.QtGui import QColor, QImage, QPixmap  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

app = QApplication(sys.argv)
from pomeloo.ui.theme import QSS  # noqa: E402

app.setStyleSheet(QSS)
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
samples = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.home() / "Documents" / "Pomelo Samples"
work = Path(tempfile.mkdtemp(prefix="pomeloo-shots-"))
for f in samples.iterdir():
    if f.is_file():
        shutil.copy(f, work / f.name)
import pomeloo.notchcore as core  # noqa: E402
from pomeloo import history  # noqa: E402

core.SHELF_FILE, history.FILE = work / "shelf.json", work / "history.json"  # never touch the real ones
W = lambda n: str(work / n)  # noqa: E731


def pump(s=0.5):
    t = time.time()
    while time.time() - t < s:
        app.processEvents()
        time.sleep(0.02)


def shot(widget, name, wait=0.6):
    widget.show()
    pump(wait)
    widget.grab().save(str(out / f"{name}.png"))
    print("saved", name, flush=True)


from pomeloo.app import load_settings  # noqa: E402
from pomeloo.ui.wheel import Wheel  # noqa: E402

settings = load_settings()
settings.update(notch=True, notch_position="center", notch_screen="primary",
                recipes=[{"name": "Web photo", "steps": [{"kind": "tool", "id": "compress", "params": {}},
                                                        {"kind": "convert", "id": "webp"}], "watch": ""}])
wheel = Wheel(settings)
for mode, f in (("convert", "photo.jpg"), ("tools", "photo.jpg"), ("actions", "photo.jpg"), ("convert", "clip.mp4"),
                ("tools", "clip.mp4"), ("tools", "document.pdf")):
    wheel.open_keyboard(QPoint(900, 500), [W(f)], mode)
    pump(0.6)
    wheel.grab().save(str(out / f"wheel-{mode}-{Path(f).suffix[1:]}.png"))
    print("saved wheel", mode, f, flush=True)
    wheel.close_wheel()

from pomeloo.ui.dialogs import ParamDialog  # noqa: E402

for tid, files in (("compress", ["photo.jpg"]), ("editImage", ["portrait.jpg"]), ("annotateImage", ["photo.jpg"]),
                   ("frameImage", ["graphic.png"]), ("cropImage", ["photo.jpg"]), ("redactImage", ["portrait.jpg"]),
                   ("createCollage", ["photo.jpg", "graphic.png", "photo.webp"]), ("trimVideo", ["clip.mp4"]),
                   ("splitVideo", ["clip.mp4"]), ("normalizeAudio", ["clip.mp4"]), ("organizePDF", ["document.pdf"]),
                   ("watermarkPDF", ["document.pdf"]), ("numberPDF", ["document.pdf"]), ("protectPDF", ["document.pdf"]),
                   ("removeMetadata", ["photo.jpg"])):
    try:
        dlg = ParamDialog(tid, [W(f) for f in files])
    except Exception as e:  # a tool id renamed or without a dialog: skip it, keep the rest
        print("skip", tid, e, flush=True)
        continue
    shot(dlg, f"tool-{tid}", 0.9)
    dlg.reject()

from pomeloo.ui.extras import HistoryDialog, RenameDialog  # noqa: E402
from pomeloo.ui.recipes import RecipeEditor, RecipesDialog  # noqa: E402
from pomeloo.ui.windows import Batch, ProgressWindow, SettingsDialog  # noqa: E402

names = ("IMG_2041.jpg", "IMG_2042.jpg", "IMG_2050.jpg")
for n in names:
    shutil.copy(work / "photo.jpg", work / n)
rn = RenameDialog([W(n) for n in names])
rn.pattern.setText("Holiday {n:02}")
rn._preview()
shot(rn, "rename")
shot(RecipeEditor(settings["recipes"][0]), "recipe-editor")
shot(RecipesDialog(settings["recipes"]), "recipes")
history.add("Convert to JPG", "convert", "jpg", [W("photo.heic")], outputs=[W("photo.jpg")])
history.add("Compress", "tool", "compress", [W("clip.mp4")], outputs=[W("clip.mov")])
shot(HistoryDialog(lambda *a: None), "history")
shot(SettingsDialog(settings), "settings")
shot(ProgressWindow("Convert to WEBP", [("photo.jpg", partial(time.sleep, 3))]), "progress", 1.2)

from pomeloo.ui.snip import ScreenText  # noqa: E402


class Stub:  # what the notch needs from the tray app
    def __init__(self):
        self.settings, self.wheel, self.screen_text = settings, wheel, ScreenText()

    def dispatch(self, *a, **k):
        pass

    run_fit = reveal_new = dispatch


from pomeloo.ui.notch import Notch  # noqa: E402

n = Notch(Stub())
shot(n, "notch-pill")
n.shelf.add([W(f) for f in ("photo.heic", "document.pdf", "clip.mp4", "notes.docx")])
n.collapse_now()
shot(n, "notch-pill-shelf")
app.clipboard().setText("Meeting moved to Thursday 10:00, room 4B")
img = QImage(640, 360, QImage.Format_RGB32)
img.fill(QColor("#3a7bd5"))
app.clipboard().setImage(img)
pump(0.4)
b = Batch("Compress", [("clip.mp4", partial(time.sleep, 5))], sources=[W("clip.mp4")])
b.fracs[0] = 0.62
n.jobs.add(b)
b.changed.emit()
for tab in ("Shelf", "Jobs", "Clipboard", "Recent", "Phone"):
    if tab == "Phone":
        n.open_phone([W("photo.jpg")])
    n.go("panel")
    n.show_tab(tab)
    shot(n, f"notch-{tab.lower()}", 0.8)
n.phone.stop()
n.suggest("photo.heic downloaded", [("→ JPG", lambda: None), ("Add to shelf", lambda: None)])
shot(n, "notch-suggest")
n.toast("Compress: Done · −62% · 4.1 MB → 1.6 MB")
shot(n, "notch-toast")
n.back_timer.timeout.disconnect()  # leaveEvent re-arms it: without a cursor over it, the drop page folds away
n._build_drop([W("photo.heic")])
n.go("drop")
shot(n, "notch-drop")

st = n.app.screen_text
st.snip.start()
st.snip.shot = QPixmap.fromImage(QImage(W("photo.jpg")))
st.snip.setGeometry(0, 0, 900, 560)
st.snip.a, st.snip.b = QPoint(30, 455), QPoint(690, 520)
shot(st.snip, "ocr-snip")
st.snip.hide()
st.toast.show_text("Copied · 12 words")
shot(st.toast, "ocr-toast")
print("done:", out, flush=True)
os._exit(0)  # don't wait on worker threads still sleeping
