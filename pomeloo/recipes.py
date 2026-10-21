"""Recipes: several steps as one wheel entry, e.g. "resize -> WebP -> strip metadata".

A recipe is {"name": str, "steps": [{"kind": "convert", "id": "webp"} |
                                     {"kind": "tool", "id": "compress", "params": {...}}],
             "watch": "" | folder}   (stored in settings.json under "recipes")
Steps run in a temp folder; only the final result lands next to the original (or in <watch>\\Done)."""
import shutil
import tempfile
from pathlib import Path

from .catalog import TOOLS, ext_of, targets, tools, unique

PREFIX = "recipe:"  # wheel / IPC id of a recipe: "recipe:<name>"
# option types a recipe can hold (visual editors like crop rectangles need a file in front of you)
SIMPLE = {"int", "float", "slider", "choice", "bool", "text", "color"}


def recipe_tools() -> list[str]:
    """Per-file tools whose options are all simple: these can be recipe steps."""
    from .tools import PARAMS, TEXT_TOOLS
    return [t for t, v in TOOLS.items() if not v[4] and t not in TEXT_TOOLS and v[3] != "folder"
            and all(p["type"] in SIMPLE or p["type"] == "meta" for p in PARAMS.get(t, []))]


def describe(steps) -> str:
    return " → ".join(s["id"].upper() if s["kind"] == "convert" else TOOLS[s["id"]][1] for s in steps)


def applies(recipe: dict, ext: str) -> bool:
    if not recipe.get("steps"):
        return False
    first = recipe["steps"][0]
    return first["id"] in (targets(ext) if first["kind"] == "convert" else tools(ext, 1))


def run(recipe: dict, src, out_dir=None) -> list[Path]:
    """Run every step on src; returns the final output(s), placed in out_dir (default: src's folder)."""
    from .engines import convert
    from .tools import run_tool
    src = Path(src)
    out_dir = Path(out_dir) if out_dir else src.parent
    with tempfile.TemporaryDirectory(prefix="pomeloo-recipe-") as tmp:
        cur = [Path(shutil.copy2(src, Path(tmp) / src.name))]
        for i, step in enumerate(recipe["steps"], 1):
            nxt = []
            for p in cur:
                if step["kind"] == "convert":
                    if step["id"] not in targets(ext_of(p)):
                        raise ValueError(f"Step {i}: {ext_of(p).upper()} can't be converted to {step['id'].upper()}.")
                    nxt.append(convert(p, step["id"]))
                else:
                    if step["id"] not in tools(ext_of(p), 1):
                        raise ValueError(f"Step {i}: {TOOLS[step['id']][1]} doesn't work on {ext_of(p).upper()}.")
                    nxt += [Path(o) for o in run_tool(step["id"], [p], step.get("params") or {})]
            cur = nxt
        out_dir.mkdir(parents=True, exist_ok=True)
        return [Path(shutil.move(str(p), str(unique(out_dir / p.name)))) for p in cur]


class Watcher:
    """Runs recipes on files that appear in their watch folders (not on what was already there).
    Results go to <folder>\\Done, so they never retrigger. A file is picked up once its size has
    stopped changing (copies in progress are left alone)."""

    def __init__(self, start_job):
        from PySide6.QtCore import QFileSystemWatcher, QTimer
        self.start_job = start_job  # start_job(recipe, path, out_dir)
        self.fs = QFileSystemWatcher()
        self.fs.directoryChanged.connect(lambda _: self.timer.start())
        self.timer = QTimer(singleShot=True, interval=1500, timeout=self._scan)
        self.recipes, self.seen, self.sizes = [], set(), {}

    def set_recipes(self, recipes):
        if self.fs.directories():
            self.fs.removePaths(self.fs.directories())
        self.recipes = [r for r in recipes if r.get("watch") and Path(r["watch"]).is_dir()]
        for r in self.recipes:
            self.fs.addPath(r["watch"])
            self.seen |= {str(p) for p in Path(r["watch"]).iterdir()}  # existing files are left alone

    def _scan(self):
        pending = False
        for r in self.recipes:
            for p in Path(r["watch"]).iterdir():
                key = str(p)
                if key in self.seen or not p.is_file() or p.suffix.lower() in (".part", ".tmp", ".crdownload"):
                    continue
                size = p.stat().st_size
                if self.sizes.get(key) != size:  # still being written: look again shortly
                    self.sizes[key] = size
                    pending = True
                    continue
                self.seen.add(key)
                self.sizes.pop(key, None)
                if applies(r, ext_of(p)):
                    self.start_job(r, p, Path(r["watch"]) / "Done")
        if pending:
            self.timer.start()


if __name__ == "__main__":  # self-check: a 3-step chain leaves exactly one result, intermediates gone
    from PIL import Image
    d = Path(tempfile.mkdtemp())
    Image.effect_noise((400, 300), 60).convert("RGB").save(d / "photo.png")  # realistic, not one flat colour
    r = {"name": "web", "steps": [{"kind": "tool", "id": "compress", "params": {"preset": "custom", "percent": 95, "resize": 50}},
                                  {"kind": "convert", "id": "webp"},
                                  {"kind": "tool", "id": "removeMetadata", "params": {"mode": "remove"}}]}
    assert applies(r, "png") and not applies(r, "srt")
    out = run(r, d / "photo.png")
    assert len(out) == 1 and out[0].suffix == ".webp" and out[0].parent == d, out
    assert sorted(p.name for p in d.iterdir()) == sorted(["photo.png", out[0].name]), list(d.iterdir())
    assert Image.open(out[0]).size == (200, 150)
    print("recipes self-check OK:", out[0].name, "|", describe(r["steps"]), "| recipe tools:", len(recipe_tools()))
