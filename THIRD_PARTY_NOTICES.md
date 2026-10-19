# Third-party software

PomeloO is licensed under the GNU AGPL-3.0 (see `LICENSE`). The Windows release bundles or
uses the components below; each keeps its own license. Source for every bundled component is
available from the linked project.

| Component | Used for | License |
|---|---|---|
| [Qt for Python (PySide6)](https://doc.qt.io/qtforpython/) | UI, media player | LGPL-3.0 |
| [PyMuPDF / MuPDF](https://github.com/pymupdf/PyMuPDF) | PDF, SVG, PDF layout | AGPL-3.0 |
| [pymupdf4llm](https://github.com/pymupdf/RAG) | PDF → Markdown | AGPL-3.0 |
| [FFmpeg](https://ffmpeg.org) (build from gyan.dev via imageio-ffmpeg) | audio and video | GPL-3.0 (built with `--enable-gpl --enable-version3`) |
| [imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg) | ships the FFmpeg binary | BSD-2-Clause |
| [pandoc](https://pandoc.org) (via pypandoc_binary) | document conversion | GPL-2.0-or-later |
| [pypandoc](https://github.com/JessicaTegner/pypandoc) | pandoc wrapper | MIT |
| [Pillow](https://python-pillow.org) | images | MIT-CMU |
| [pillow-heif](https://github.com/bigcat88/pillow_heif) (libheif, libde265, x265) | HEIC | BSD-3-Clause (libheif LGPL-3.0) |
| [pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) | PDF → DOCX | MIT |
| [python-pptx](https://github.com/scanny/python-pptx) | PDF → PPTX | MIT |
| [openpyxl](https://openpyxl.readthedocs.io) | XLSX | MIT |
| [odfpy](https://github.com/eea/odfpy) | ODS | Apache-2.0 / GPL-2.0 / LGPL-2.1 |
| [xlrd](https://github.com/python-excel/xlrd) | XLS | BSD |
| [pandas](https://pandas.pydata.org), [NumPy](https://numpy.org) | spreadsheets, image math | BSD-3-Clause |
| [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) | QR codes | Apache-2.0 |
| [pywin32](https://github.com/mhammond/pywin32) | Windows shell, COM | PSF |
| [PyWinRT](https://github.com/pywinrt/pywinrt) | Windows OCR and face detection | MIT |
| [PyInstaller](https://pyinstaller.org) | building the .exe | GPL-2.0-or-later with bootloader exception |

Not bundled, used only if present or downloaded on first use:

| Component | When | License |
|---|---|---|
| [LibreOffice](https://www.libreoffice.org) | slide rendering when no Office suite is installed; downloaded from The Document Foundation and checksum-verified, stored in `%LOCALAPPDATA%\PomeloO\libreoffice` | MPL-2.0 |
| WPS Office, Microsoft PowerPoint | slide rendering, if installed (driven over COM) | proprietary, not distributed |
| Windows `tar.exe` (libarchive) | RAR extraction | BSD-2-Clause, part of Windows |

Sample `tests/fixtures/sample.rar` comes from the [libarchive](https://github.com/libarchive/libarchive)
test suite (BSD-2-Clause).
