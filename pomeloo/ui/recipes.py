"""Recipe list and editor (dark glass). A recipe is a list of steps; see pomeloo/recipes.py."""
import copy

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (QComboBox, QDialog, QDoubleSpinBox, QFileDialog, QHBoxLayout, QLabel, QLineEdit,
                               QSpinBox, QVBoxLayout, QWidget)

from .theme import GlassMixin, Swatch, Toggle, button, footer, muted, section


def clear(layout):
    """Empty a layout now (deleteLater alone leaves old rows painted until the loop comes back)."""
    while layout.count():
        if w := layout.takeAt(0).widget():
            w.hide()
            w.setParent(None)
            w.deleteLater()


def _option(p, value, store):
    """One compact control for a simple tool option; writes into store[p['key']]."""
    key, t = p["key"], p["type"]
    if t in ("int", "slider"):
        w = QSpinBox(minimum=int(p.get("min", -100)), maximum=int(p.get("max", 100000)))
        w.setSuffix(p.get("suffix", ""))
        w.setValue(int(value))
        w.valueChanged.connect(lambda v: store.__setitem__(key, v))
    elif t == "float":
        w = QDoubleSpinBox(minimum=float(p.get("min", -100)), maximum=float(p.get("max", 100)), decimals=2)
        w.setValue(float(value))
        w.valueChanged.connect(lambda v: store.__setitem__(key, v))
    elif t == "choice":
        w = QComboBox()
        for o in p["options"]:
            w.addItem(str(o), o)
        w.setCurrentIndex(max(0, w.findData(value)))
        w.currentIndexChanged.connect(lambda i: store.__setitem__(key, w.itemData(i)))
    elif t == "bool":
        w = Toggle(bool(value))
        w.toggled.connect(lambda v: store.__setitem__(key, v))
    elif t == "color":
        w = Swatch(value)
        w.clicked.connect(lambda: store.__setitem__(key, w.color))  # Swatch updates .color on pick
    else:  # text
        w = QLineEdit(str(value))
        w.textChanged.connect(lambda v: store.__setitem__(key, v))
    return w


class RecipeEditor(GlassMixin, QDialog):
    def __init__(self, recipe=None, taken=()):
        super().__init__()
        from ..catalog import TOOLS, all_input_exts, targets
        from ..recipes import recipe_tools
        self.r = copy.deepcopy(recipe) if recipe else {"name": "", "steps": [], "watch": ""}
        self.taken = {n.lower() for n in taken}
        body = self._glass("Recipe", "", self.reject)
        self.setMinimumWidth(560)
        body.addWidget(section("Name"))
        self.name = QLineEdit(self.r["name"])
        self.name.setPlaceholderText("e.g. Web photo")
        body.addWidget(self.name)
        body.addWidget(section("Steps"))
        self.steps_box = QVBoxLayout()
        body.addLayout(self.steps_box)
        self.add = QComboBox()
        self.add.addItem("Add a step…", None)
        for t in recipe_tools():
            self.add.addItem(TOOLS[t][1], ("tool", t))
        for f in sorted({t for e in all_input_exts() for t in targets(e)}):
            self.add.addItem(f"Convert to {f.upper()}", ("convert", f))
        self.add.activated.connect(self._add_step)
        body.addWidget(self.add)
        body.addWidget(section("Watch folder"))
        row = QHBoxLayout()
        self.watch_on = Toggle(bool(self.r.get("watch")))
        self.watch_label = muted("")
        row.addWidget(self.watch_on)
        row.addWidget(self.watch_label, 1)
        row.addWidget(button("Choose folder…", self._pick_folder))
        self.watch_on.toggled.connect(lambda on: on or self._set_watch(""))
        body.addLayout(row)
        body.addWidget(muted("New files in that folder are processed automatically; results go to its Done folder."))
        self.error = QLabel("")
        self.error.setStyleSheet("color:#ff6961")
        body.addWidget(self.error)
        body.addLayout(footer("Save", self._save, self.reject))
        self._set_watch(self.r.get("watch", ""))
        self._rebuild()

    def _set_watch(self, folder):
        self.r["watch"] = folder
        self.watch_label.setText(folder or "Off: run it from the wheel or right-click menu")
        self.watch_on.setChecked(bool(folder))

    def _pick_folder(self):
        if f := QFileDialog.getExistingDirectory(self, "Watch folder"):
            self._set_watch(f)

    def _add_step(self, i):
        data = self.add.itemData(i)
        self.add.setCurrentIndex(0)
        if not data:
            return
        kind, ident = data
        step = {"kind": kind, "id": ident}
        if kind == "tool":
            from ..tools import defaults
            step["params"] = defaults(ident)
        self.r["steps"].append(step)
        self._rebuild()

    def _rebuild(self):
        from ..catalog import TOOLS
        from ..recipes import SIMPLE
        from ..tools import PARAMS
        clear(self.steps_box)
        if not self.r["steps"]:
            self.steps_box.addWidget(muted("No steps yet."))
        for i, s in enumerate(self.r["steps"]):
            step = QWidget()
            col = QVBoxLayout(step)
            col.setContentsMargins(0, 0, 0, 4)
            col.setSpacing(4)
            top = QHBoxLayout()
            top.addWidget(QLabel(f"{i + 1}. " + (f"Convert to {s['id'].upper()}" if s["kind"] == "convert"
                                                  else TOOLS[s["id"]][1])))
            top.addStretch()
            top.addWidget(button("×", lambda _=False, k=i: (self.r["steps"].pop(k), self._rebuild())))
            col.addLayout(top)
            opts = [p for p in PARAMS.get(s["id"], []) if s["kind"] == "tool" and p["type"] in SIMPLE]
            if opts:  # options on their own line under the step
                row = QHBoxLayout()
                row.setContentsMargins(18, 0, 0, 0)
                for p in opts:
                    row.addWidget(muted(p["label"]))
                    row.addWidget(_option(p, s["params"].get(p["key"], p["default"]), s["params"]))
                row.addStretch()
                col.addLayout(row)
            self.steps_box.addWidget(step)
        self.adjustSize()

    def _save(self):
        name = self.name.text().strip().replace('"', "").replace("%", "")  # both mean something in menu commands
        if not name:
            return self.error.setText("Give the recipe a name.")
        if name.lower() in self.taken:
            return self.error.setText("Another recipe already has that name.")
        if not self.r["steps"]:
            return self.error.setText("Add at least one step.")
        self.r["name"] = name
        self.accept()


class RecipesDialog(GlassMixin, QDialog):
    """All recipes; result_recipes() after Save."""

    def __init__(self, recipes):
        super().__init__()
        self.recipes = copy.deepcopy(recipes)
        body = self._glass("Recipes", "", self.reject)
        self.setMinimumWidth(560)
        intro = muted("A recipe runs several steps in one go, e.g. resize → WebP → remove metadata. "
                      "It appears with a ★ in the Tools wheel and the right-click menu.")
        intro.setWordWrap(True)
        body.addWidget(intro)
        self.rows = QVBoxLayout()
        body.addLayout(self.rows)
        body.addWidget(button("New recipe", lambda: self._edit(None)), 0, Qt.AlignLeft)
        body.addLayout(footer("Save", self.accept, self.reject))
        self._fill()

    def _fill(self):
        from ..recipes import describe
        clear(self.rows)
        if not self.recipes:
            self.rows.addWidget(muted("No recipes yet."))
        for i, r in enumerate(self.recipes):
            row = QWidget()
            lay = QHBoxLayout(row)
            lay.setContentsMargins(0, 0, 0, 0)
            text = QVBoxLayout()
            text.setSpacing(0)
            text.addWidget(QLabel("★ " + r["name"]))
            text.addWidget(muted(describe(r["steps"]) + (f"  ·  watching {r['watch']}" if r.get("watch") else "")))
            lay.addLayout(text, 1)
            lay.addWidget(button("Edit", lambda _=False, k=i: self._edit(k)))
            lay.addWidget(button("Delete", lambda _=False, k=i: (self.recipes.pop(k), self._fill())))
            self.rows.addWidget(row)
        self.adjustSize()

    def _edit(self, index):
        current = self.recipes[index] if index is not None else None
        taken = [r["name"] for k, r in enumerate(self.recipes) if k != index]
        ed = RecipeEditor(current, taken)
        if ed.exec() == QDialog.Accepted:
            if index is None:
                self.recipes.append(ed.r)
            else:
                self.recipes[index] = ed.r
            self._fill()

    def result_recipes(self):
        return self.recipes
