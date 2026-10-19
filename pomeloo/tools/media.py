"""Audio and video tools (ffmpeg). Times in seconds, regions as fractions [x, y, w, h]."""
import json
import re
import subprocess
import tempfile
from pathlib import Path

from ..catalog import ext_of, stem_of
from ..engines.media import AUDIO_CODEC, EVEN, FF, VIDEO_CODEC, codec_args, ff, probe, video_only

LOSSY_ENC = {"mp3": "libmp3lame", "m4a": "aac", "ogg": "libvorbis", "opus": "libopus", "wma": "wmav2"}
_NOWIN = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _even_box(src, rect):
    W, H = probe(src)["size"]
    x, y, w, h = rect
    ev = lambda v: int(v) // 2 * 2
    return ev(w * W), ev(h * H), ev(x * W), ev(y * H)


def _stderr(*args) -> str:
    return subprocess.run([FF, "-hide_banner", *map(str, args)], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", creationflags=_NOWIN).stderr


# ---------- metadata (keys: "title" = file level, "stream N/key", "chapter N/key") ----------
def read_metadata(src: Path) -> dict:
    out, prefix, in_meta = {}, "File", False
    for line in _stderr("-i", src).splitlines():
        s = line.strip()
        if m := re.match(r"Stream #\d+:(\d+)", s):
            prefix, in_meta = f"stream {m[1]}", False
        elif m := re.match(r"Chapter #\d+:(\d+)", s):
            prefix, in_meta = f"chapter {m[1]}", False
        elif s == "Metadata:":
            in_meta = True
        elif in_meta and (m := re.match(r"(\w[\w-]*)\s*:\s?(.*)$", s)) and line.startswith("    "):
            out[f"{prefix}/{m[1]}"] = m[2]
        elif in_meta and not line.startswith("      "):
            in_meta = False
    return out


def metadata(src: Path, dst: Path, mode="remove", fields=None):
    if mode == "remove":
        ff("-i", src, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", dst)
        return dst
    meta = []
    for k, v in (fields or {}).items():
        group, _, key = k.rpartition("/")
        if group.startswith("stream "):
            meta += [f"-metadata:s:{group.split()[1]}", f"{key}={v}"]
        elif group.startswith("chapter "):
            meta += [f"-metadata:c:{group.split()[1]}", f"{key}={v}"]
        else:
            meta += ["-metadata", f"{key}={v}"]
    ff("-i", src, "-map", "0", "-c", "copy", *meta, dst)
    return dst


# ---------- shared ----------
def compress(src: Path, dst: Path, percent=50, target_kb=0, resize=100):
    info, ext = probe(src), ext_of(dst)
    dur = max(info["duration"], 0.1)
    target = target_kb * 1024 if target_kb else src.stat().st_size * percent / 100
    total_kbps = target * 8 / dur / 1000
    if not info["has_video"]:
        if ext == "flac":  # wav/aiff/flac -> max-compression FLAC (lossless)
            ff("-i", src, "-vn", "-c:a", "flac", "-compression_level", "12", dst)
        else:
            kbps = int(min(320, max(32, total_kbps)))
            ff("-i", src, "-vn", "-c:a", LOSSY_ENC[ext], "-b:a", f"{kbps}k", dst)
        return dst
    f = min(100, int(resize or 100)) / 100
    vf = EVEN if f == 1 else f"scale=trunc(iw*{f}/2)*2:trunc(ih*{f}/2)*2"
    akbps = 96 if info["has_audio"] else 0
    vkbps = int(max(80, total_kbps - akbps) * 0.97)  # 3% container overhead
    if ext in ("mp4", "mov", "mkv"):  # two-pass x264 lands close to the target size
        audio = ["-c:a", "aac", "-b:a", f"{akbps}k"] if akbps else ["-an"]
        with tempfile.TemporaryDirectory() as t:
            base = ["-i", src, "-vf", vf, "-c:v", "libx264", "-preset", "medium", "-b:v", f"{vkbps}k",
                    "-pix_fmt", "yuv420p", "-passlogfile", str(Path(t) / "pass")]
            ff(*base, "-pass", "1", "-an", "-f", "null", "NUL")
            ff(*base, "-pass", "2", *audio, dst)
    else:
        vcodec = {"webm": ["-c:v", "libvpx-vp9", "-row-mt", "1"], "avi": ["-c:v", "mpeg4"],
                  "wmv": ["-c:v", "wmv2"]}[ext]
        acodec = {"webm": "libopus", "avi": "libmp3lame", "wmv": "wmav2"}[ext]
        ff("-i", src, "-vf", vf, *vcodec, "-b:v", f"{vkbps}k",
           *(["-c:a", acodec, "-b:a", f"{akbps}k"] if akbps else ["-an"]), dst)
    return dst


_SILENCE = ("silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse,"
            "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse")


def trim(src: Path, dst: Path, start=0.0, end=0.0, trim_silence=False):
    """Keep start..end; trim_silence also strips silence at the beginning and end (audio only)."""
    info = probe(src)
    end = float(end) or info["duration"]
    af = ["-af", _SILENCE] if trim_silence and not info["has_video"] else []
    ff("-ss", float(start), "-i", src, "-t", max(0.01, end - float(start)), *af,
       *codec_args(ext_of(dst), info["has_video"]), dst)
    return dst


# ---------- audio ----------
def measure_loudness(src) -> dict:
    """EBU R128 analysis: input_i (LUFS), input_tp (dBTP), input_lra (LU), ..."""
    err = _stderr("-i", src, "-vn", "-af", "loudnorm=print_format=json", "-f", "null", "NUL")
    return json.loads(err[err.rindex("{"):err.rindex("}") + 1])


def normalize(src: Path, dst: Path, loudness=-16, lra=11, true_peak=-1.5):
    """Two-pass loudnorm (measure, then apply linearly) for an accurate result."""
    info, m = probe(src), measure_loudness(src)
    af = (f"loudnorm=I={loudness}:TP={true_peak}:LRA={lra}:measured_I={m['input_i']}:"
          f"measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:"
          f"offset={m['target_offset']}:linear=true")
    if info["has_video"]:
        ff("-i", src, "-af", af, "-ar", "48000", "-c:v", "copy", "-c:a", "aac", dst)
    else:
        ff("-i", src, "-af", af, "-ar", "48000", *AUDIO_CODEC[ext_of(dst)], dst)
    return dst


SIZES = {"landscape": (1280, 720), "portrait": (720, 1280), "square": (1080, 1080)}


def visualize(src: Path, dst: Path, style="waves", color="#ff8a00", image="", shape="landscape"):
    """MP4 with an animated waveform/spectrum, or a still image, over the audio."""
    W, H = SIZES.get(shape, SIZES["landscape"])
    enc = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "192k", "-shortest"]
    if style == "image" and image:
        ff("-loop", "1", "-i", image, "-i", src, "-filter_complex",
           f"[0:v]scale={W}:{H}:force_original_aspect_ratio=decrease,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,fps=10[v]",
           "-map", "[v]", "-map", "1:a", "-tune", "stillimage", *enc, dst)
        return dst
    c = "0x" + color.lstrip("#")
    viz = (f"showwaves=s={W}x{H}:mode=cline:rate=30:colors={c}" if style == "waves" else
           f"showspectrum=s={W}x{H}:mode=combined:color=fire:slide=scroll")
    ff("-i", src, "-filter_complex", f"[0:a]{viz},format=yuv420p[v]", "-map", "[v]", "-map", "0:a", *enc, dst)
    return dst


def channels(src: Path, dst: Path, channels=1, left=100, right=100):
    """Mono or stereo, with independent left/right volume (percent)."""
    l, r = float(left) / 100, float(right) / 100
    pan = (f"pan=mono|c0={l / 2:.3f}*c0+{r / 2:.3f}*c1" if int(channels) == 1 else
           f"pan=stereo|c0={l:.3f}*c0|c1={r:.3f}*c1")
    ff("-i", src, "-vn", "-af", f"aformat=channel_layouts=stereo,{pan}", *AUDIO_CODEC[ext_of(dst)], dst)
    return dst


def bleep(src: Path, dst: Path, ranges=((0.0, 1.0),), mode="beep", frequency=1000):
    on = "+".join(f"between(t,{float(a)},{float(b)})" for a, b in ranges) or "0"
    codec = AUDIO_CODEC[ext_of(dst)]
    if mode == "mute":
        ff("-i", src, "-af", f"volume=0:enable='{on}'", *codec, dst)
    else:
        graph = (f"[0:a]volume=0:enable='{on}'[m];sine=f={int(frequency)}:sample_rate=44100,"
                 f"volume=0.25,volume=0:enable='not({on})'[b];[m][b]amix=inputs=2:duration=first:normalize=0[a]")
        ff("-i", src, "-filter_complex", graph, "-map", "[a]", *codec, dst)
    return dst


def waveform_png(src, out: Path, width=900, height=120, color="#ff8a00"):
    ff("-i", src, "-filter_complex", f"aformat=channel_layouts=mono,showwavespic=s={width}x{height}:colors={color}",
       "-frames:v", "1", out)
    return out


# ---------- video ----------
def mute(src: Path, dst: Path):
    ff("-i", src, "-map", "0:v", "-c", "copy", "-an", dst)
    return dst


def crop(src: Path, dst: Path, rect=(0, 0, 1, 1), aspect="free", width=0, height=0):
    """Crop to rect (or centred aspect); width/height > 0 force exact output pixels. Audio is kept."""
    from .image import ASPECTS, centre_rect
    W, H = probe(src)["size"]
    full = tuple(rect or (0, 0, 1, 1)) == (0, 0, 1, 1)
    if full and width and height:
        rect = centre_rect(W, H, int(width) / int(height))
    elif full and aspect in ASPECTS:
        rect = centre_rect(W, H, ASPECTS[aspect])
    w, h, x, y = _even_box(src, rect or (0, 0, 1, 1))
    vf = f"crop={w}:{h}:{x}:{y}"
    if width and height:
        ow, oh = int(width) // 2 * 2, int(height) // 2 * 2
        vf += f",scale={ow}:{oh}:force_original_aspect_ratio=increase,crop={ow}:{oh}"
    ff("-i", src, "-map", "0:v", "-map", "0:a?", "-vf", vf, *video_only(ext_of(dst)), dst)
    return dst


def speed(src: Path, dst: Path, factor=2.0):
    """atempo keeps the pitch; silent videos skip the audio chain."""
    f = float(factor)
    graph, maps = f"[0:v]setpts=PTS/{f}[v]", ["-map", "[v]"]
    if probe(src)["has_audio"]:
        chain, r = [], f
        while r > 2:
            chain.append("atempo=2.0")
            r /= 2
        while r < 0.5:
            chain.append("atempo=0.5")
            r /= 0.5
        chain.append(f"atempo={r}")
        graph += f";[0:a]{','.join(chain)}[a]"
        maps += ["-map", "[a]"]
    ff("-i", src, "-filter_complex", graph, *maps, *VIDEO_CODEC[ext_of(dst)], dst)
    return dst


def snapshots(src: Path, dst: Path, count=1, times=()):
    """Full-resolution PNGs at exact times (seconds), or `count` evenly spaced frames."""
    dur = probe(src)["duration"]
    times = [float(t) for t in times] or (
        [dur / 2] if int(count) <= 1 else [(i + 0.5) * dur / int(count) for i in range(int(count))])
    if len(times) == 1:
        ff("-ss", times[0], "-i", src, "-frames:v", "1", dst)
        return dst
    folder = dst.with_name(f"{stem_of(src)} Snapshots")
    folder.mkdir(exist_ok=True)
    for i, t in enumerate(times, 1):
        ff("-ss", t, "-i", src, "-frames:v", "1", folder / f"{stem_of(src)} {i}.png")
    return folder


def split(src: Path, folder: Path, parts=2, seconds=0, points=(), precise=True):
    """Split at custom points (seconds), into equal parts, or fixed-length clips, into one folder.
    precise re-encodes so cuts land exactly; otherwise stream copy cuts on keyframes (fast)."""
    folder.mkdir()
    dur = probe(src)["duration"]
    if points:
        cuts = sorted(float(p) for p in points if 0 < float(p) < dur)
    else:
        seg = float(seconds) or dur / max(1, int(parts))
        cuts = [seg * i for i in range(1, int(dur / seg + 0.999)) if seg * i < dur - 0.05]
    times = ",".join(f"{c:.3f}" for c in cuts) or f"{dur:.3f}"
    pattern = folder / f"{stem_of(src)} %d.{ext_of(src)}"
    common = ["-f", "segment", "-segment_times", times, "-reset_timestamps", "1", "-segment_start_number", "1"]
    if precise:
        ff("-i", src, "-map", "0:v", "-map", "0:a?", "-force_key_frames", times,
           *VIDEO_CODEC[ext_of(src)], *common, pattern)
    else:
        ff("-i", src, "-map", "0", "-c", "copy", *common, pattern)
    return folder


def redact(src: Path, dst: Path, rects=(), style="blur", color="#000000", times=()):
    """times[i] = [start, end] limits region i to part of the video (missing/None = whole video)."""
    W, H = probe(src)["size"]
    graph, last = [], "0:v"
    fill = "black" if style == "black" else "0x" + color.lstrip("#")
    for i, (x, y, w, h) in enumerate(rects):
        bw, bh, bx, by = max(2, int(w * W) // 2 * 2), max(2, int(h * H) // 2 * 2), int(x * W), int(y * H)
        rng = times[i] if i < len(times) and times[i] else None
        en = f":enable='between(t,{float(rng[0])},{float(rng[1])})'" if rng else ""
        if style in ("black", "color"):
            graph.append(f"[{last}]drawbox=x={bx}:y={by}:w={bw}:h={bh}:color={fill}:t=fill{en}[v{i}]")
        else:
            graph.append(f"[{last}]split[a{i}][b{i}];[b{i}]crop={bw}:{bh}:{bx}:{by},"
                         f"boxblur={max(2, min(bw, bh) // 8)}:2[c{i}];[a{i}][c{i}]overlay={bx}:{by}{en}[v{i}]")
        last = f"v{i}"
    if not graph:
        raise ValueError("Draw at least one region to redact.")
    ff("-i", src, "-filter_complex", ";".join(graph), "-map", f"[{last}]", "-map", "0:a?",
       *video_only(ext_of(dst)), dst)
    return dst


def join(srcs, dst: Path):
    """Concatenate in the given order onto the first clip's canvas; silent clips get silence."""
    infos = [probe(s) for s in srcs]
    W, H = infos[0]["size"]
    W, H = W // 2 * 2, H // 2 * 2
    args, parts = [], []
    for n, (s, info) in enumerate(zip(srcs, infos)):
        args += ["-i", s]
        parts.append(f"[{n}:v]scale={W}:{H}:force_original_aspect_ratio=decrease,"
                     f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v{n}]")
        src_a = f"[{n}:a]" if info["has_audio"] else f"anullsrc=r=48000:cl=stereo,atrim=duration={info['duration']},"
        parts.append(f"{src_a}aresample=48000,aformat=channel_layouts=stereo[a{n}]")
    cat = "".join(f"[v{n}][a{n}]" for n in range(len(srcs)))
    graph = ";".join(parts) + f";{cat}concat=n={len(srcs)}:v=1:a=1[v][a]"
    ff(*args, "-filter_complex", graph, "-map", "[v]", "-map", "[a]", *VIDEO_CODEC[ext_of(dst)], dst)
    return dst
