# PomeloO

**Drag a file, tap a key, pick a format.** PomeloO is a local file converter and file toolbox for
Windows. While you drag a file in Explorer, tap **Shift** and a wheel of formats appears under the
cursor; drop the file on one and the converted copy appears next to the original.

Everything runs on your PC. Files are never uploaded.

- **275+ conversions**: images (JPG, PNG, WebP, HEIC, AVIF, TIFF, BMP, SVG), audio, video, GIF, PDF,
  Word, Markdown, EPUB, slides, spreadsheets, subtitles and archives (including RAR input).
- **27 tools**: compress (to a % or exact size), edit photos with live preview, annotate, add a
  background, crop, redact with automatic face/text detection, collage, trim, split, join, speed,
  frame snapshots, normalize loudness, bleep, audio visualizer, merge/split/organize PDF, metadata,
  QR reader, extract archives.
- **6 actions** on any file or folder: Share, Float (a shelf to drag from), Copy, Move, Copy Path,
  Terminal.

See [docs/features.md](docs/features.md) for the full list.

## Install

1. Download `PomeloO-windows.zip` from [Releases](../../releases) and unzip it anywhere.
2. Run `PomeloO.exe`. It lives in the tray (orange icon).
3. Optional: tray menu → **Add to Explorer menu** for the right-click menu.

Requires Windows 10 1809+ or Windows 11, 64-bit.

## Use

| Do this | To |
|---|---|
| Drag a file in Explorer, tap **Shift** | convert |
| Drag a file, tap **Ctrl** | open tools |
| Drag a file or folder, tap **Alt** | file actions |
| Drop files on the round pad (bottom right) | open the wheel without keys |
| Select files, press **Ctrl+Shift+Space** | use the wheel with the keyboard |
| Right-click → Show more options → **PomeloO** | classic menu |

Keys, hotkey, pad and sound are in the tray menu → **Settings**.

### Presentations
PPT/PPTX are rendered by a real Office engine for full fidelity: an installed LibreOffice, WPS Office
or PowerPoint. If none is installed, PomeloO downloads a private copy of LibreOffice the first time you
convert slides (about 375 MB, from The Document Foundation, checksum-verified, no admin rights, stored
in `%LOCALAPPDATA%\PomeloO\libreoffice`). This is the only time PomeloO uses the network.

## Build from source

```powershell
uv venv --python 3.13 .venv
uv pip install --python .venv\Scripts\python.exe -e . pyinstaller
.venv\Scripts\python.exe tests\test_convert.py        # converts every pair and runs every tool
.venv\Scripts\python.exe -m pomeloo                    # run the tray app from source
.venv\Scripts\pyinstaller --noconfirm --windowed --name PomeloO --icon ../assets/pomeloo.ico --distpath dist --workpath build `
  --specpath build --paths . --collect-all imageio_ffmpeg --collect-all pypandoc `
  --collect-all pillow_heif --collect-all zxingcpp --collect-all pymupdf `
  --collect-submodules pomeloo --collect-submodules winrt --collect-binaries winrt scripts\pomeloo_entry.py
```

Command line (useful for scripting):

```powershell
pomeloo list photo.jpg
pomeloo convert webp photo.jpg
pomeloo tool compress video.mp4 --set percent=40
pomeloo --register        # or --unregister: Explorer right-click menu (current user only)
```

## Privacy

No telemetry, no accounts, no uploads. The only network access is the optional one-time LibreOffice
download described above.

## License

[GNU AGPL-3.0](LICENSE). Bundled components keep their own licenses, see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Inspired by the drag-and-tap converter idea of Tangerine for macOS. PomeloO is an independent,
from-scratch project and is not affiliated with it.
