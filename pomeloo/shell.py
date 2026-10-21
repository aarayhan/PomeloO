"""Explorer context menu (per-user, HKCU only). Built from catalog.py, so it always matches the wheel.

  <file>   ▸ PomeloO ▸ Convert to ▸ PNG / WEBP …     (SystemFileAssociations\\.ext)
                    ▸ Tools ▸ Compress / Crop …
  <any>    ▸ PomeloO Actions ▸ Share / Float / Copy …   (* and Directory)
Windows 11 shows these under "Show more options" (Shift+F10).
"""
import os
import subprocess
import sys
import winreg
from pathlib import Path

from .catalog import ACTIONS, ALIASES, TOOLS, all_input_exts, targets, tools

ROOT = r"Software\Classes"
APPDIR = Path(os.environ.get("APPDATA", Path.home())) / "PomeloO"
ICON = APPDIR / "pomeloo.ico"


def launcher() -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable]
    pyw = Path(sys.executable).with_name("pythonw.exe")
    return [str(pyw if pyw.exists() else sys.executable), "-m", "pomeloo"]


def start_app_detached():
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    subprocess.Popen(launcher(), creationflags=flags, close_fds=True, cwd=str(Path.home()))


def _cmd(*args) -> str:
    from .native import find
    quoted = " ".join(f'"{a}"' for a in args)  # recipe names can contain spaces
    send = find("pomeloo-send.exe")  # C sender: milliseconds instead of a Python boot per file...
    if send and send.with_name("PomeloO.exe").exists():  # ...but it can only start a built app
        return f'"{send}" {quoted} "%1"'
    return " ".join(f'"{a}"' for a in launcher()) + f' run {quoted} "%1"'


def is_registered() -> bool:
    try:
        winreg.OpenKey(winreg.HKEY_CURRENT_USER, rf"{ROOT}\*\shell\PomeloOActions").Close()
        return True
    except OSError:
        return False


RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"


def set_autostart(on: bool):
    """Start PomeloO when the user signs in (per-user Run key, no admin). Rewritten every start so the
    entry follows the app if its folder moves. Only for the built app: running from source must not
    put a developer's venv in everyone's sign-in (or replace the installed app's entry)."""
    if not getattr(sys, "frozen", False):
        return
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, RUN, 0, winreg.KEY_WRITE) as k:
        if on:
            winreg.SetValueEx(k, "PomeloO", 0, winreg.REG_SZ, " ".join(f'"{a}"' for a in launcher()))
        else:
            try:
                winreg.DeleteValue(k, "PomeloO")
            except FileNotFoundError:
                pass


def compact_install():
    """Once per build: NTFS-compress our own files with LZX, the compression Windows uses for its own
    system files (807 MB -> ~280 MB on disk; starts are as fast or faster). Runs at idle priority in
    the background; files already loaded by this process are skipped (/i) and stay as they are."""
    if not getattr(sys, "frozen", False):
        return
    root = Path(sys.executable).parent
    stamp = f"{root}|{Path(sys.executable).stat().st_mtime_ns}"
    mark = APPDIR / "compacted.txt"
    try:
        if mark.read_text(encoding="utf-8") == stamp:
            return
    except OSError:
        pass
    APPDIR.mkdir(parents=True, exist_ok=True)
    mark.write_text(stamp, encoding="utf-8")
    subprocess.Popen(["compact.exe", "/c", f"/s:{root}", "/i", "/q", "/exe:lzx", "*"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)


def _key(path, values: dict):
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_WRITE) as k:
        for name, v in values.items():
            winreg.SetValueEx(k, name, 0, winreg.REG_SZ, v)


def _icon():
    return {"Icon": str(ICON)} if ICON.exists() else {}


def _menu(base, label, entries) -> int:
    """entries: [(key, label, command)] -> cascading submenu at base."""
    _key(base, {"MUIVerb": label, "SubCommands": "", **_icon()})
    for i, (k, text, cmd) in enumerate(entries):
        leaf = rf"{base}\shell\{i:02}{k}"
        _key(leaf, {"MUIVerb": text, "MultiSelectModel": "Player"})
        _key(leaf + r"\command", {"": cmd})
    return 1 + 2 * len(entries)


def _ext_keys():
    """Canonical ext -> every spelling Windows may use."""
    spell = {e: [e] for e in all_input_exts() if e != "rtfd"}
    for alias, canon in ALIASES.items():
        if canon in spell:
            spell[canon].append(alias)
    return spell


def register(recipes=()) -> int:
    from .recipes import PREFIX, applies
    unregister()  # start clean so removed tools/recipes don't linger
    n = 0
    for ext, spellings in _ext_keys().items():
        conv = [(t, "GZIP (.tar.gz)" if t == "gz" else t.upper(), _cmd("convert", t)) for t in targets(ext)]
        tls = [(t, TOOLS[t][1], _cmd("tool", t)) for t in dict.fromkeys(tools(ext, 1) + tools(ext, 2))]
        tls += [(f"r{i}", "★ " + r["name"], _cmd("tool", PREFIX + r["name"]))
                for i, r in enumerate(recipes) if applies(r, ext)]
        if not conv and not tls:
            continue
        for sp in spellings:
            base = rf"{ROOT}\SystemFileAssociations\.{sp}\shell\PomeloO"
            _key(base, {"MUIVerb": "PomeloO", "SubCommands": "", **_icon()})
            n += 1
            if conv:
                n += _menu(base + r"\shell\1convert", "Convert to", conv)
            if tls:
                n += _menu(base + r"\shell\2tools", "Tools", tls)
    acts = [(a, v[1], _cmd("action", a)) for a, v in ACTIONS.items()]
    for scope in ("*", "Directory"):
        n += _menu(rf"{ROOT}\{scope}\shell\PomeloOActions", "PomeloO Actions", acts)
    return n


def _delete_tree(path) -> int:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_ALL_ACCESS) as k:
            subs = []
            while True:
                try:
                    subs.append(winreg.EnumKey(k, len(subs)))
                except OSError:
                    break
        n = sum(_delete_tree(rf"{path}\{s}") for s in subs)
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)
        return n + 1
    except FileNotFoundError:
        return 0


def unregister() -> int:
    n = 0
    for spellings in _ext_keys().values():
        for sp in spellings:
            n += _delete_tree(rf"{ROOT}\SystemFileAssociations\.{sp}\shell\PomeloO")
    for scope in ("*", "Directory"):
        n += _delete_tree(rf"{ROOT}\{scope}\shell\PomeloOActions")
    return n
