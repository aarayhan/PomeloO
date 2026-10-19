"""Subtitles (SRT/VTT/TXT) and archives (ZIP/TAR/TAR.GZ, RAR input) using the stdlib."""
import gzip
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

_TS = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")


# ---------- subtitles ----------
def _sec(m) -> float:
    h, mi, s, ms = m.groups()
    return int(h or 0) * 3600 + int(mi) * 60 + int(s) + int(ms.ljust(3, "0")) / 1000


def _fmt(t: float, sep: str) -> str:
    ms = round(t * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}{sep}{ms % 1000:03}"


def read_cues(src: Path) -> list[tuple[float, float, str]]:
    text = src.read_text(encoding="utf-8-sig", errors="replace").replace("\r\n", "\n")
    cues = []
    for block in re.split(r"\n\s*\n", text):
        lines = block.strip().split("\n")
        for i, line in enumerate(lines):
            if "-->" in line:
                a, b = (_TS.search(x) for x in line.split("-->", 1))
                if a and b:
                    cues.append((_sec(a), _sec(b), "\n".join(lines[i + 1:]).strip()))
                break
    return cues


def subtitle_convert(src: Path, dst: Path, target: str):
    cues = read_cues(src)
    if target == "srt":
        out = "\n".join(f"{i}\n{_fmt(a, ',')} --> {_fmt(b, ',')}\n{t}\n"
                        for i, (a, b, t) in enumerate(cues, 1))
    elif target == "vtt":
        out = "WEBVTT\n\n" + "\n".join(f"{_fmt(a, '.')} --> {_fmt(b, '.')}\n{t}\n" for a, b, t in cues)
    else:  # txt: plain dialogue, markup stripped
        out = "\n".join(re.sub(r"<[^>]+>|\{[^}]+\}", "", t) for _, _, t in cues) + "\n"
    dst.write_text(out, encoding="utf-8")


# ---------- archives ----------
BSDTAR = Path(r"C:\Windows\System32\tar.exe")  # libarchive: reads RAR on Windows 10 1803+/11


def extract(src: Path, dst_dir: Path):
    """Extract safely (no path traversal) into dst_dir."""
    dst_dir.mkdir(parents=True, exist_ok=True)
    name = src.name.lower()
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            z.extractall(dst_dir)  # zipfile strips absolute and '..' parts
    elif tarfile.is_tarfile(src):
        with tarfile.open(src) as t:
            t.extractall(dst_dir, filter="data")
    elif name.endswith(".gz"):  # plain gzip of a single file
        with gzip.open(src) as g, open(dst_dir / Path(name).stem, "wb") as f:
            shutil.copyfileobj(g, f)
    else:  # rar and friends
        p = subprocess.run([str(BSDTAR), "-xf", str(src), "-C", str(dst_dir)], capture_output=True,
                           text=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if p.returncode:
            raise RuntimeError("Could not extract archive: " + p.stderr.strip()[-300:])


def pack(src_dir: Path, dst: Path, target: str):
    items = sorted(src_dir.iterdir())
    if target == "zip":
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(src_dir.rglob("*")):
                z.write(f, f.relative_to(src_dir))
    else:
        with tarfile.open(dst, "w:gz" if target == "gz" else "w") as t:
            for f in items:
                t.add(f, f.name)


def archive_convert(src: Path, dst: Path, target: str):
    with tempfile.TemporaryDirectory() as t:
        extract(src, Path(t))
        pack(Path(t), dst, target)
