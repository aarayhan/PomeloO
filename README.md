# PomeloO

**Drag a file, tap a key, pick a format.** PomeloO is a local file converter and file toolbox for
Windows. While you drag a file in Explorer, tap **Shift** and a wheel of formats appears under the
cursor; drop the file on one and the converted copy appears next to the original.

Everything runs on your PC. Files are never uploaded.

- **275+ conversions**: images (JPG, PNG, WebP, HEIC, AVIF, TIFF, BMP, SVG), audio, video, GIF, PDF,
  Word, Markdown, EPUB, slides, spreadsheets, subtitles and archives (including RAR input).
- **34 tools**: compress (to a % or exact size), edit photos with live preview, annotate, add a
  background, crop, redact with automatic face/text detection, collage, trim, split, join, speed,
  frame snapshots, normalize loudness, bleep, audio visualizer, burn in subtitles, merge/split/organize
  PDF, PDF password/watermark/page numbers, copy text (OCR), searchable PDF, metadata, QR reader,
  extract archives.
- **8 actions** on any file or folder: Share, Float (a shelf to drag from), Copy, Move, Copy Path,
  Terminal, Rename (patterns with date taken and numbering), Send to Phone (QR code, both ways).
- **Recipes** (several steps as one ★ entry, optionally watching a folder), **History** with undo,
  **copy text from the screen** (Win+Ctrl+T) and **paste a copied image as a file** (Ctrl+V in a folder).

See [docs/features.md](docs/features.md) for the full list.

## Install

1. Download **`PomeloO-Setup-x.y.z.exe`** from [Releases](../../releases/latest) and run it. No admin rights
   needed: it installs for your user, adds a Start menu entry and (optional) the Explorer right-click menu.
2. Windows may say *"Windows protected your PC"* because the installer isn't code-signed: **More info →
   Run anyway**.
3. PomeloO lives in the tray (orange icon) and starts with Windows. On first start it compresses its own
   folder with Windows' file compression (about 690 MB → 240 MB on disk).

No installer wanted? `PomeloO-x.y.z-portable.zip` runs from any folder (tray → **Add to Explorer menu**
for the right-click menu). Uninstall from Settings → Apps; that also removes the menu and autostart.

Requires Windows 10 1809+ or Windows 11, 64-bit.

## Use

| Do this | To |
|---|---|
| Drag a file in Explorer, tap **Shift** | convert |
| Drag a file, tap **Ctrl** | open tools |
| Drag a file or folder, tap **Alt** | file actions |
| Drop files on the round pad (bottom right) | open the wheel without keys |
| Select files, press **Ctrl+Shift+Space** | use the wheel with the keyboard (no selection: what you copied) |
| Press **Win+Ctrl+T**, drag over text | copy text from anything on screen |
| Copy an image, **Ctrl+V** in a folder | save it there as a PNG |
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
uv pip install --python .venv\Scripts\python.exe -e . pyinstaller ziglang
.venv\Scripts\python.exe tests\test_convert.py        # converts every pair and runs every tool
powershell -File scripts\build.ps1 -NativeOnly         # C helpers only (needed to run from source)
.venv\Scripts\python.exe -m pomeloo                    # run the tray app from source
powershell -File scripts\build.ps1                     # full build -> dist\PomeloO
powershell -File scripts\build.ps1 -Installer          # + dist\PomeloO-Setup-<version>.exe (Inno Setup 6)
```

`native\` holds two small C helpers, compiled with `zig cc` (installed by pip, no Visual Studio):
`pomeloo-send.exe` is what the Explorer menu runs (it hands the request to the tray app in a few
milliseconds), and `pomeloo_native.dll` watches for the drag gesture on a native thread so the
Python side sleeps until something happens.

Command line (useful for scripting):

```powershell
pomeloo list photo.jpg
pomeloo convert webp photo.jpg
pomeloo tool compress video.mp4 --set percent=40
pomeloo --register        # or --unregister: Explorer right-click menu (current user only)
```

## Privacy

No telemetry, no accounts, no uploads. Network use: the optional one-time LibreOffice download described
above, and Send to Phone, which serves files only on your local network, behind a random link, while its
window is open.

## License

[GNU AGPL-3.0](LICENSE). Bundled components keep their own licenses, see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Inspired by the drag-and-tap converter idea of Tangerine for macOS. PomeloO is an independent,
from-scratch project and is not affiliated with it.
