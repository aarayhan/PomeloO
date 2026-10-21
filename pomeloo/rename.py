"""Batch rename with a pattern. Tokens: {name} {n} {date} {time} {folder}; format specs work, so
{n:03} gives 001. {date}/{time} are when the photo or video was taken (EXIF / container), else the
file's modified time. Renames happen in place, in two phases, so swapping names is safe."""
import functools
import re
import subprocess
from datetime import datetime
from pathlib import Path

TOKENS = "{name}  {n}  {n:03}  {date}  {time}  {folder}"
_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def taken(path: Path) -> datetime:
    try:
        from PIL import Image
        with Image.open(path) as im:
            exif = im.getexif()
            raw = exif.get_ifd(0x8769).get(36867) or exif.get(306)  # DateTimeOriginal, DateTime
        if raw:
            return datetime.strptime(str(raw).strip()[:19], "%Y:%m:%d %H:%M:%S")
    except Exception:
        pass
    try:  # videos and audio: the container's creation_time, as ffmpeg prints it
        from .engines.media import FF
        err = subprocess.run([FF, "-hide_banner", "-i", str(path)], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", creationflags=0x08000000).stderr
        if m := re.search(r"creation_time\s*:\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", err):
            return datetime.fromisoformat(m[1] + "+00:00").astimezone().replace(tzinfo=None)
    except Exception:
        pass
    return datetime.fromtimestamp(path.stat().st_mtime)


@functools.lru_cache(maxsize=8192)
def _taken_cached(path: str, mtime_ns: int) -> datetime:  # the preview re-plans on every keystroke
    return taken(Path(path))


class _Keep(dict):
    def __missing__(self, key):  # unknown {token} stays as typed
        return "{" + key + "}"


def _natural(p: Path):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", p.name)]


def plan(paths, pattern="{name}", start=1) -> list[tuple[Path, Path]]:
    """(old, new) for every file, in natural name order; names that would clash get ' 2', ' 3'..."""
    files = sorted((Path(p) for p in paths), key=_natural)
    moving = {p.resolve() for p in files}
    used, out = set(), []
    for i, p in enumerate(files):
        t = _taken_cached(str(p), p.stat().st_mtime_ns) if ("{date" in pattern or "{time" in pattern) else None
        values = _Keep(name=p.stem if p.is_file() else p.name, n=start + i, folder=p.parent.name,
                       date=t.strftime("%Y-%m-%d") if t else "", time=t.strftime("%H.%M.%S") if t else "")
        try:
            stem = pattern.format_map(values)
        except (ValueError, IndexError):  # e.g. a stray "{" while typing
            stem = pattern
        stem = _BAD.sub("_", stem).strip().rstrip(".") or p.stem
        suffix = p.suffix if p.is_file() else ""
        new, k = p.with_name(stem + suffix), 2
        while new.name.lower() in used or (new.exists() and new.resolve() not in moving):
            new, k = p.with_name(f"{stem} {k}{suffix}"), k + 1
        used.add(new.name.lower())
        out.append((p, new))
    return out


def apply(pairs) -> list[tuple[str, str]]:
    """Rename for real; returns what changed (for undo). Two phases: old -> temp -> new. If any step
    fails (a file open in another app...), everything already moved goes back, then the error is raised."""
    pairs = [(Path(a), Path(b)) for a, b in pairs if Path(a) != Path(b)]
    temps, done = [], []
    try:
        for i, (a, b) in enumerate(pairs):
            t = a.with_name(f".pomeloo-rename-{i}-{a.name}")
            a.rename(t)
            temps.append((t, a, b))
        for t, a, b in temps:
            t.rename(b)
            done.append((t, a, b))
    except OSError:
        for t, a, b in reversed(done):  # new -> temp
            b.rename(t)
        for t, a, b in reversed(temps):  # temp -> original
            t.rename(a)
        raise
    return [(str(a), str(b)) for _, a, b in done]


def undo(done) -> int:
    return len(apply([(b, a) for a, b in done if Path(b).exists()]))


if __name__ == "__main__":  # self-check: numbering in natural order, clashes, swap, undo
    import tempfile
    d = Path(tempfile.mkdtemp())
    for n in ("b.txt", "a.txt", "a 10.txt", "a 9.txt"):
        (d / n).write_text(n)
    pairs = plan(d.iterdir(), "photo {n:02}")
    assert [(a.name, b.name) for a, b in pairs] == [("a 9.txt", "photo 01.txt"), ("a 10.txt", "photo 02.txt"),
                                                    ("a.txt", "photo 03.txt"), ("b.txt", "photo 04.txt")], pairs
    done = apply(pairs)
    assert (d / "photo 02.txt").read_text() == "a 10.txt"
    undo(done)
    assert sorted(p.name for p in d.iterdir()) == ["a 10.txt", "a 9.txt", "a.txt", "b.txt"]
    apply([(d / "a.txt", d / "b.txt"), (d / "b.txt", d / "a.txt")])
    assert (d / "a.txt").read_text() == "b.txt" and (d / "b.txt").read_text() == "a.txt"
    assert [b.name for _, b in plan([d / "a.txt", d / "b.txt"], "same")] == ["same.txt", "same 2.txt"]
    assert [b.name for _, b in plan([d / "a.txt"], "{date}")][0][:2] == "20"
    (d / "taken.txt").write_text("in the way")  # second target exists: apply fails and rolls back
    try:
        apply([(d / "a.txt", d / "z.txt"), (d / "b.txt", d / "taken.txt")])
        raise AssertionError("expected a failure")
    except OSError:
        pass
    assert sorted(p.name for p in d.iterdir() if p.suffix == ".txt" and p.stem in "abz") == ["a.txt", "b.txt"]
    assert not list(d.glob(".pomeloo-rename-*")), "temp names left behind"
    print("rename self-check OK")
