"""Self-update. Once a day (Settings → Update automatically) PomeloO reads the latest release from GitHub.
An installed copy downloads the new setup, checks its SHA-256 against the digest GitHub publishes, and runs it
silently once you haven't touched the PC for a couple of minutes and nothing is in progress; the installer
starts PomeloO again. Portable and source copies only get a notice."""
import ctypes
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
from pathlib import Path

from PySide6.QtCore import QObject, QTimer, Signal

from . import __version__

API = "https://api.github.com/repos/aarayhan/PomeloO/releases/latest"
DOWNLOADS = "https://github.com/aarayhan/PomeloO/releases/download/"
DIR = Path(tempfile.gettempdir()) / "pomeloo-update"
IDLE_S = 120  # ponytail: "not in use" = no keyboard/mouse input for 2 minutes and nothing running
NO_WINDOW = 0x08000000


def parse(v: str) -> tuple:
    return tuple(int(x) for x in v.strip().lstrip("v").split(".")[:3])


def newer(tag: str, current: str = __version__) -> bool:
    try:
        return parse(tag) > parse(current)
    except ValueError:
        return False


def installed() -> bool:
    """Installed by the setup (Inno Setup leaves unins000.exe next to the app), not portable or from source."""
    return bool(getattr(sys, "frozen", False)) and (Path(sys.executable).parent / "unins000.exe").exists()


def release_info(rel: dict) -> dict | None:
    """The parts of a GitHub release we need, or None when it isn't newer than this copy."""
    tag = rel.get("tag_name", "")
    if rel.get("draft") or rel.get("prerelease") or not newer(tag):
        return None
    v = tag.lstrip("v")
    asset = next((a for a in rel.get("assets", []) if a.get("name") == f"PomeloO-Setup-{v}.exe"), {})
    return {"version": v, "page": rel.get("html_url", ""), "url": asset.get("browser_download_url", ""),
            "sha256": (asset.get("digest") or "").removeprefix("sha256:").lower()}


def check() -> dict | None:
    req = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": f"PomeloO/{__version__}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return release_info(json.load(r))


def download(info: dict) -> Path:
    """The verified setup; ValueError when the release has no checksum or the file doesn't match it."""
    if not info["sha256"] or not info["url"].startswith(DOWNLOADS):
        raise ValueError("this release has no verifiable installer")
    DIR.mkdir(parents=True, exist_ok=True)
    dst = DIR / f"PomeloO-Setup-{info['version']}.exe"
    subprocess.run(["curl.exe", "-fsSL", "--retry", "3", "-o", str(dst), info["url"]],
                   check=True, timeout=1800, creationflags=NO_WINDOW)
    with open(dst, "rb") as f:
        ok = hashlib.file_digest(f, "sha256").hexdigest() == info["sha256"]
    if not ok:
        dst.unlink(missing_ok=True)
        raise ValueError("the download doesn't match its checksum")
    return dst


def idle_seconds() -> float:
    class LastInput(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]
    li = LastInput(ctypes.sizeof(LastInput), 0)
    ctypes.windll.user32.GetLastInputInfo(ctypes.byref(li))
    return (ctypes.windll.kernel32.GetTickCount() - li.dwTime) / 1000


class Updater(QObject):
    """Needs from the app: settings, notify(text), busy() and qapp."""
    done = Signal(object)  # (info or None, manual, error) from the worker thread

    def __init__(self, app):
        super().__init__()
        self.app, self.ready = app, None
        shutil.rmtree(DIR, ignore_errors=True)  # an earlier update's setup, already installed
        self.done.connect(self._done)
        self.daily = QTimer(self, interval=24 * 3600_000, timeout=self.check)
        self.daily.start()
        QTimer.singleShot(5 * 60_000, self.check)  # after start-up and the one-time disk compression
        self.waiting = QTimer(self, interval=60_000, timeout=self._install_when_idle)

    def check(self, manual=False):
        if manual or self.app.settings.get("auto_update", True):
            threading.Thread(target=self._work, args=(manual,), daemon=True).start()

    def _work(self, manual):
        try:
            info = check()
            if info and installed():
                info["setup"] = download(info)
            self.done.emit((info, manual, None))
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            self.done.emit((None, manual, str(e)))

    def _done(self, result):
        info, manual, error = result
        if error or not info:
            if manual:
                self.app.notify(f"Couldn't check for updates: {error}" if error else f"PomeloO {__version__} is up to date.")
            return
        if "setup" not in info:  # portable / from source: say so once per version
            if manual or self.app.settings.get("update_told") != info["version"]:
                self.app.notify(f"PomeloO {info['version']} is out: download it from GitHub Releases.")
                self.app._set("update_told", info["version"])
            return
        self.ready = info
        if manual:
            self.app.notify(f"Updating to PomeloO {info['version']}…")
        self._install_when_idle(now=manual)
        if self.ready:
            self.waiting.start()

    def _install_when_idle(self, now=False):
        if self.ready is None or self.app.busy() or (not now and idle_seconds() < IDLE_S):
            return
        self.waiting.stop()
        subprocess.Popen([str(self.ready["setup"]), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
                         creationflags=0x00000008 | 0x00000200, close_fds=True)  # detached, own group
        self.ready = None
        self.app.qapp.quit()  # the installer replaces the files, then starts PomeloO again


if __name__ == "__main__":  # self-check of the pure parts
    assert newer("v9.0.0") and not newer("v0.1.0") and not newer(f"v{__version__}") and not newer("junk")
    assert newer("v1.10.0", "1.9.9") and not newer("v1.2", "1.2.0")
    rel = {"tag_name": "v9.9.9", "html_url": "p", "assets": [
        {"name": "PomeloO-9.9.9-portable.zip", "browser_download_url": DOWNLOADS + "v9.9.9/z", "digest": "sha256:aa"},
        {"name": "PomeloO-Setup-9.9.9.exe", "browser_download_url": DOWNLOADS + "v9.9.9/s", "digest": "sha256:AB"}]}
    assert release_info(rel) == {"version": "9.9.9", "page": "p", "url": DOWNLOADS + "v9.9.9/s", "sha256": "ab"}
    assert release_info({**rel, "prerelease": True}) is None and release_info({**rel, "tag_name": "v0.0.1"}) is None
    try:
        download({"version": "9.9.9", "url": "https://evil.example/s.exe", "sha256": "ab"})
        raise AssertionError("downloaded from outside the PomeloO releases")
    except ValueError:
        pass
    print("update self-check OK; latest on GitHub:", check() or "this copy is current")
