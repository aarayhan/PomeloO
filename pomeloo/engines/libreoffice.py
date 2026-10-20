"""Private LibreOffice engine for full-fidelity slide rendering when no Office suite is installed.

Downloaded once from The Document Foundation, SHA-256 verified against TDF's published checksum,
and unpacked per-user with an MSI administrative install: no admin rights, nothing registered
system-wide, deletable by removing %LOCALAPPDATA%\\PomeloO\\libreoffice.
"""
import hashlib
import os
import re
import shutil
import subprocess
import threading
import urllib.request
from pathlib import Path

BASE = "https://download.documentfoundation.org/libreoffice/stable/"
HOME = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "PomeloO" / "libreoffice"
_lock = threading.Lock()
notify = lambda message: None  # noqa: E731 - the tray app swaps in a notification callback


def installed() -> Path | None:
    """soffice.exe of a previously unpacked engine (newest version first)."""
    if not HOME.exists():
        return None
    for d in sorted((p for p in HOME.iterdir() if p.is_dir()), reverse=True):
        for exe in (d / "program" / "soffice.exe", d / "LibreOffice" / "program" / "soffice.exe"):
            if exe.exists():
                return exe
    return None


def _latest() -> str:
    html = urllib.request.urlopen(BASE, timeout=30).read().decode()
    versions = re.findall(r'href="(\d+\.\d+\.\d+)/"', html)
    return max(versions, key=lambda v: tuple(map(int, v.split("."))))


def ensure() -> Path:
    """Return soffice.exe, downloading and unpacking the engine the first time."""
    with _lock:  # several slide jobs may ask at once; download only once
        if exe := installed():
            return exe
        if os.environ.get("POMELOO_NO_DOWNLOAD"):
            raise RuntimeError("Slides need WPS Office, PowerPoint or LibreOffice (download disabled).")
        version = _latest()
        url = f"{BASE}{version}/win/x86_64/LibreOffice_{version}_Win_x86-64.msi"
        expected = urllib.request.urlopen(url + ".sha256", timeout=30).read().decode().split()[0].lower()
        msi = HOME / f"LibreOffice_{version}.msi.part"
        notify(f"Downloading the slide engine (LibreOffice {version}, about 375 MB, one time)…")
        # curl.exe (built into Windows) writes the file, not Python: a Microsoft Store Python would
        # redirect its own AppData writes into a private sandbox that msiexec can't see.
        subprocess.run(["curl.exe", "-fsSL", "--retry", "3", "--create-dirs", "-o", str(msi), url],
                       check=True, timeout=3600, creationflags=subprocess.CREATE_NO_WINDOW)
        with open(msi, "rb") as f:
            digest = hashlib.file_digest(f, "sha256")
        if digest.hexdigest() != expected:
            msi.unlink(missing_ok=True)
            raise RuntimeError("The LibreOffice download did not match its official checksum; nothing was installed.")
        notify("Unpacking the slide engine…")
        target = HOME / version
        shutil.rmtree(target, ignore_errors=True)
        try:  # /a = administrative install: unpacks the files only, no admin, no registration
            subprocess.run(["msiexec", "/a", str(msi), "/qn", f"TARGETDIR={target}"], check=True, timeout=1800)
        finally:
            msi.unlink(missing_ok=True)
        if not (exe := installed()):
            raise RuntimeError("Unpacking LibreOffice failed.")
        notify("Slide engine ready.")
        return exe
