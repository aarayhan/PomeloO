"""Audio/video via ffmpeg (bundled by imageio-ffmpeg)."""
from pathlib import Path
import re
import subprocess
import threading

import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
_NOWIN = getattr(subprocess, "CREATE_NO_WINDOW", 0)

AUDIO_CODEC = {
    "mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
    "m4a": ["-c:a", "aac", "-b:a", "192k"],
    "wav": ["-c:a", "pcm_s16le"],
    "flac": ["-c:a", "flac"],
    "ogg": ["-c:a", "libvorbis", "-q:a", "5"],
    "opus": ["-c:a", "libopus", "-b:a", "128k"],
    "aiff": ["-c:a", "pcm_s16be"],
    "wma": ["-c:a", "wmav2", "-b:a", "192k"],
}
_H264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p"]
VIDEO_CODEC = {
    "mp4": _H264 + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
    "mov": _H264 + ["-c:a", "aac", "-b:a", "160k"],
    "mkv": _H264 + ["-c:a", "aac", "-b:a", "160k"],
    "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"],
    "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"],
    "wmv": ["-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "160k"],
}
EVEN = "scale=trunc(iw/2)*2:trunc(ih/2)*2"


def ff(*args, cwd=None) -> str:
    """Run ffmpeg; raise with the tail of stderr on failure. Returns stderr.
    When a progress reporter is active (see pomeloo.progress), real progress is read from ffmpeg."""
    from ..progress import report, reporter
    args = [str(a) for a in args]
    if reporter() is None:
        p = subprocess.run([FF, "-hide_banner", "-y", *args], capture_output=True,
                           text=True, encoding="utf-8", errors="replace", creationflags=_NOWIN, cwd=cwd)
        if p.returncode:
            raise RuntimeError("ffmpeg: " + "\n".join(p.stderr.strip().splitlines()[-4:]))
        return p.stderr
    duration = float(args[args.index("-t") + 1]) if "-t" in args else (
        probe(args[args.index("-i") + 1])["duration"] if "-i" in args else 0)
    p = subprocess.Popen([FF, "-hide_banner", "-y", "-progress", "pipe:1", "-nostats", *args],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                         errors="replace", creationflags=_NOWIN, cwd=cwd)
    err = []
    t = threading.Thread(target=lambda: err.append(p.stderr.read()), daemon=True)  # avoid pipe deadlock
    t.start()
    for line in p.stdout:
        if line.startswith("out_time_us=") and duration > 0:
            try:
                report(int(line.split("=", 1)[1]) / 1e6 / duration)
            except ValueError:
                pass  # "N/A" before the first frame
    p.wait()
    t.join()
    stderr = err[0] if err else ""
    if p.returncode:
        raise RuntimeError("ffmpeg: " + "\n".join(stderr.strip().splitlines()[-4:]))
    return stderr


def probe(src) -> dict:
    """Duration (s), size (w,h), has_audio, audio bitrate (kbps) parsed from `ffmpeg -i`."""
    p = subprocess.run([FF, "-hide_banner", "-i", str(src)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", creationflags=_NOWIN)
    err = p.stderr
    info = {"duration": 0.0, "size": None, "has_audio": "Audio:" in err, "has_video": False,
            "abitrate": None, "fps": 30.0}
    if m := re.search(r"Duration: (\d+):(\d+):([\d.]+)", err):
        h, mi, s = m.groups()
        info["duration"] = int(h) * 3600 + int(mi) * 60 + float(s)
    for line in err.splitlines():
        if "Video:" in line and "attached pic" not in line and (m := re.search(r"(\d{2,5})x(\d{2,5})", line)):
            info["size"], info["has_video"] = (int(m[1]), int(m[2])), True
            if f := re.search(r"([\d.]+) fps", line):
                info["fps"] = float(f[1])
        if "Audio:" in line and (m := re.search(r"(\d+) kb/s", line)):
            info["abitrate"] = int(m[1])
    return info


def codec_args(ext: str, has_video=True) -> list[str]:
    if ext in VIDEO_CODEC and has_video:
        return VIDEO_CODEC[ext]
    return AUDIO_CODEC.get(ext, [])


def video_only(ext: str) -> list[str]:
    """Video encoder args for ext with the audio copied untouched (same container in and out)."""
    args, out, skip = VIDEO_CODEC[ext], [], False
    for a in args:
        if skip:
            skip = False
        elif a in ("-c:a", "-b:a", "-q:a"):
            skip = True
        else:
            out.append(a)
    return out + ["-c:a", "copy"]


def convert(src: Path, dst: Path, target: str):
    if target == "gif":
        ff("-i", src, "-filter_complex",
           "fps=12,scale='min(iw,640)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
           "-loop", "0", dst)
    elif target in AUDIO_CODEC:
        ff("-i", src, "-vn", *AUDIO_CODEC[target], dst)
    else:
        ff("-i", src, "-vf", EVEN, *VIDEO_CODEC[target], dst)
