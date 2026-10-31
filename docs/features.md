# PomeloO features

PomeloO converts and edits files locally on Windows. Every result is saved as a new file next to the
original (`photo.webp`, `photo Compressed.jpg`, `photo 2.webp` if the name is taken). Nothing is uploaded.

## Ways to use it
| Gesture | What happens |
|---|---|
| Drag a file in Explorer, tap **Shift** | Convert wheel at the cursor; drop on a format |
| Drag a file in Explorer, tap **Ctrl** | Tools wheel |
| Drag a file in Explorer, tap **Alt** | Actions wheel (works for folders and mixed selections) |
| Drop files on the floating pad | Wheel opens around the pad |
| Select files, press **Ctrl+Shift+Space** | Wheel with keyboard control: arrows, Enter, Esc. Nothing selected? It uses what you copied (files, an image, text) |
| Press **Win+Ctrl+T**, drag over the screen | The text (and any QR code) is on the clipboard; a just-copied image is read without dragging |
| Copy an image, **Ctrl+V** in an Explorer folder or on the desktop | The image is saved there as a PNG |
| Right-click → Show more options → **PomeloO** | Classic Explorer menu: Convert to / Tools / Actions |
| Tray → Receive from phone / Recipes / History | Phone transfer, multi-step recipes, undo |

The wheel keys and shortcuts can be changed in Settings (tray icon). PomeloO starts with Windows
(Settings → Start with Windows).

## Conversions
Targets never include the source format. RAR, PPT, XLS, RTF, RTFD and Pages are input-only.

| Input | Outputs |
|---|---|
| JPG PNG WebP HEIC TIFF AVIF BMP SVG | JPG PNG WebP HEIC TIFF AVIF BMP PDF |
| MP3 M4A WAV FLAC OGG Opus AIFF WMA | each other |
| MP4 MOV MKV WebM AVI WMV | each other, GIF, MP3 |
| GIF | MP4 MOV MKV WebM AVI WMV |
| PDF | DOCX PPTX XLSX JPG PNG EPUB TXT MD (every page, 300 DPI images) |
| PPT PPTX | PDF JPG PNG |
| XLSX XLS ODS CSV TSV | XLSX ODS CSV TSV PDF |
| DOCX MD RTF RTFD Pages | DOCX PDF TXT MD HTML EPUB PNG JPG |
| TXT | DOCX PDF MD HTML EPUB PNG JPG |
| EPUB | PDF DOCX TXT MD HTML |
| HTML | DOCX PDF TXT MD EPUB |
| SRT VTT | SRT VTT TXT |
| ZIP TAR GZIP RAR | ZIP TAR GZIP (.tar.gz) |

## Tools
Single file / several files selected. With several files, per-file tools run on each file;
"combine" tools make one output from the whole selection.

| File type | Tools |
|---|---|
| Photos | Compress, Metadata, Edit photo, Annotate, Add background, Crop, Redact, Read QR, Copy text (OCR), Searchable PDF · several: Compress, Metadata, Crop, Create PDF, Collage, Copy text, Searchable PDF |
| SVG | several: Create PDF, Collage |
| Audio | Compress, Metadata, Normalize, Visualizer, Trim, Channels, Bleep |
| Video | Compress, Metadata, Remove audio, Trim, Crop, Speed, Snapshots, Split, Redact, Burn in subtitles · several: Join |
| GIF | Metadata |
| PDF | Compress, Metadata, Split, Organize, Copy text, Searchable PDF, Add/remove password, Watermark, Page numbers · several: Merge |
| Archives | Extract |

Tool details:
- **Compress**: target % or exact size in KB, presets, optional resize. WAV/AIFF become lossless FLAC.
- **Metadata**: view grouped fields (file, camera, location, streams, chapters), search, edit, or strip everything.
- **Edit photo**: exposure, contrast, highlights, shadows, saturation, temperature, tint, clarity, dehaze,
  sharpness, noise reduction, grain, vignette, rotate, flip, black and white, with a live preview.
- **Annotate**: pen, highlighter, arrow, line, rectangle, ellipse, numbered callouts, text, magnifier, images.
- **Add background**: solid colour, gradient, another image or a blurred copy; aspect, spacing, corners, shadow.
- **Crop** (photo/video): drag a region (aspect-locked, movable) or enter exact pixel dimensions.
- **Redact** photo: movable regions, pixelate/blur/colour, automatic face and text detection
  (Windows' built-in detectors). Redact video: blur/colour with a time range per region.
- **Trim** (audio/video): frame-accurate player with In/Out marks; optional silence removal for audio.
- **Snapshots**: pick exact frames, or N evenly spaced frames, as full-resolution PNG.
- **Split video**: custom points, equal parts or fixed length; exact cuts or fast keyframe cuts.
- **Join videos**: reorder clips; output is MP4 on the first clip's canvas.
- **Normalize**: two-pass EBU R128 with loudness, range and true-peak targets; input/output levels shown.
- **Visualizer**: animated waveform, spectrum or still image; landscape, portrait or square.
- **Channels**: mono/stereo with independent left/right volume. **Bleep**: beep or mute marked ranges.
  Audio tools have Original / Result playback.
- **Organize PDF**: reorder, rotate, duplicate and delete pages. **Merge**: reorder before merging.
- **Copy text (OCR)**: Windows' own OCR; scanned PDF pages are read, real text layers are used as is. The text
  goes to the clipboard. **Searchable PDF**: an invisible text layer over scans and photos, so you can search,
  select and copy.
- **Password**: AES-256; remove needs the current password. **Watermark**: text, size, opacity, angle, colour.
  **Page numbers**: "1", "Page 1", "1 / 10" or "Page 1 of 10", six positions, any start number.
- **Burn in subtitles**: draws an .srt/.vtt/.ass into the picture; the subtitle file with the video's name is
  used automatically.
- **Recipes**: several steps (any convert + the tools with simple options) as one ★ entry in the Tools wheel
  and the right-click menu. A recipe can watch a folder: new files there are processed into its Done folder.

## Actions
Share (Windows share sheet), Float (always-on-top shelf to drag files from), Copy (files to clipboard),
Move (choose folder), Copy Path (one path per line), Terminal (Windows Terminal at the folder),
Rename (pattern with {name} {n} {n:03} {date} {time} {folder}, live preview), Send to Phone (QR code:
the phone downloads the files over Wi-Fi and can send files back to Downloads\PomeloO).

## Notch
A black pill at the top centre of the screen (Settings → Notch: position, which screen, which parts).
- **Hover** opens a small panel: **Jobs** (progress of every conversion, Cancel, size saved, Show),
  **Shelf** (files you park there, kept across restarts; drag them out anywhere, Shift+drag drops them
  converted: PNG→JPG, DOCX→PDF, MKV→MP4…; hover for a preview), **Clipboard** (the last six things you
  copied, never saved to disk, password-manager content skipped), **Recent** (latest results + Undo),
  **Phone** (the QR code to send/receive, right in the notch), and **Copy text from screen**.
- **Drag a file from Explorer to the top of the screen** and the notch turns into drop zones: convert
  to the usual formats, Tools…, Actions…, Shelf, Phone, **Fit WhatsApp** (photos ~1 MB, video/PDF under
  16 MB), **Fit Email** (under 25 MB), **Fit Web** (WebP ≤1920 px, ~300 KB) and your ★ recipes.
- **Ideas**: a new file in Downloads gets one-click next steps (HEIC → JPG, MKV → MP4, big PDF →
  compress…); a copied screenshot can be saved as a file, read (OCR), annotated or sent to the phone.
- Notices (done, size saved, files from the phone) appear in the notch instead of Windows balloons.
- It steps aside for full-screen apps, games and presentations, never appears in screenshots or screen
  sharing, and skips its animation on battery saver. Float uses the notch's shelf when the notch is on.

## History
Tray → History lists recent jobs: Show, Undo (results go to the Recycle Bin, renames are reversed) and
Again (same files, same settings). Passwords are never stored.

## Engines
Pillow + pillow-heif (images), PyMuPDF (PDF, SVG), ffmpeg (audio/video), pandoc (documents),
pdf2docx, python-pptx, pandas/openpyxl/odfpy/xlrd (spreadsheets), zxing-cpp (QR), Windows OCR and
FaceDetector (redaction, text), libarchive `tar.exe` built into Windows (RAR). Two small C helpers
(`native\`): the Explorer menu sender and the drag / Ctrl+V watcher. Presentations are rendered
by LibreOffice, WPS Office or PowerPoint, whichever is available; if none is, PomeloO downloads a
private copy of LibreOffice once (official build, checksum-verified) so slides convert at full fidelity.

## Known limits
- Pages output is not possible (Apple's format is closed); Pages input reads the embedded preview.
- PDF → XLSX extracts ruled tables; PDFs without tables become one text line per row.
- CSV/TSV export takes the first sheet of a workbook.
- OCR reads the languages installed in Windows (Settings → Time & language → Language).
- Phone transfer needs the PC and phone on the same network; Windows may ask once to allow it on
  Private networks.
- Wheel-while-dragging and Ctrl+V-in-folders watch the keyboard state only to spot those gestures;
  nothing is recorded.

## Questions
- **Is it free?** Yes: no ads, no account, GNU AGPL-3.0.
- **Does it work offline?** Yes. Conversions, tools and OCR run on the PC. Only the update check, the one-time LibreOffice download (if needed) and phone transfer use the network.
- **Is anything uploaded?** No. Files never leave the PC; phone transfer goes straight to a phone on the same network.
- **Which Windows versions?** Windows 10 (1809 or newer) and Windows 11, 64-bit.
