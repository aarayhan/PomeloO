"""Recent jobs, newest first, in %APPDATA%\\PomeloO\\history.json: undo (outputs to the Recycle Bin,
renames reversed) and 'run again with the same settings'."""
import json
import time
import uuid
from pathlib import Path

from .shell import APPDIR

FILE = APPDIR / "history.json"
MAX = 100


def load() -> list[dict]:
    try:
        return json.loads(FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _save(entries):
    APPDIR.mkdir(parents=True, exist_ok=True)
    FILE.write_text(json.dumps(entries[:MAX], indent=1, default=str), encoding="utf-8")


def add(title: str, kind: str, ident: str, sources, outputs=(), params=None, renames=None):
    """kind/ident/params are what App.dispatch needs to run it again. Passwords are never written to
    disk: such entries keep no params, so 'Again' asks for the options (and the password) again."""
    if params and any("password" in k for k in params):
        params = None
    entry = {"key": uuid.uuid4().hex, "time": time.strftime("%Y-%m-%d %H:%M"), "title": title, "kind": kind, "id": ident,
             "params": params, "sources": [str(s) for s in sources], "outputs": [str(o) for o in outputs],
             "renames": renames or []}
    _save([entry, *load()])


def undo(key: str) -> str:
    """Undo one entry (by its key: jobs finishing meanwhile shift positions); returns a short report.
    Outputs go to the Recycle Bin (restorable)."""
    from PySide6.QtCore import QFile
    entries = load()
    match = [i for i, x in enumerate(entries) if x.get("key") == key]
    if not match:
        return "Already undone."
    e = entries.pop(match[0])
    if e["renames"]:
        from .rename import undo as unrename
        msg = f"Renamed {unrename(e['renames'])} back."
    else:
        gone = [o for o in e["outputs"] if Path(o).exists() and QFile.moveToTrash(o)]
        msg = f"Moved {len(gone)} file(s) to the Recycle Bin."
    _save(entries)
    return msg
