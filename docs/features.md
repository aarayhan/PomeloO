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
| Select files, press **Ctrl+Shift+Space** | Wheel with keyboard control: arrows, Enter, Esc |
| Right-click → Show more options → **PomeloO** | Classic Explorer menu: Convert to / Tools / Actions |

The wheel keys and the hotkey can be changed in Settings (tray icon).

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
| Photos | Compress, Metadata, Edit photo, Annotate, Add background, Crop, Redact, Read QR · several: Compress, Metadata, Crop, Create PDF, Collage |
| SVG | several: Create PDF, Collage |
| Audio | Compress, Metadata, Normalize, Visualizer, Trim, Channels, Bleep |
| Video | Compress, Metadata, Remove audio, Trim, Crop, Speed, Snapshots, Split, Redact · several: Join |
| GIF | Metadata |
| PDF | Compress, Metadata, Split, Organize · several: Merge |
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

## Actions
Share (Windows share sheet), Float (always-on-top shelf to drag files from), Copy (files to clipboard),
Move (choose folder), Copy Path (one path per line), Terminal (Windows Terminal at the folder).

## Engines
Pillow + pillow-heif (images), PyMuPDF (PDF, SVG), ffmpeg (audio/video), pandoc (documents),
pdf2docx, python-pptx, pandas/openpyxl/odfpy/xlrd (spreadsheets), zxing-cpp (QR), Windows OCR and
FaceDetector (redaction), libarchive `tar.exe` built into Windows (RAR). Presentations are rendered
by LibreOffice, WPS Office or PowerPoint, whichever is available; if none is, PomeloO downloads a
private copy of LibreOffice once (official build, checksum-verified) so slides convert at full fidelity.

## Known limits
- Pages output is not possible (Apple's format is closed); Pages input reads the embedded preview.
- PDF → XLSX extracts ruled tables; PDFs without tables become one text line per row.
- CSV/TSV export takes the first sheet of a workbook.
