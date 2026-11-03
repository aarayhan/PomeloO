# Third-party software in PomeloO for Mac

PomeloO is licensed under the GNU AGPL-3.0 (see `LICENSE`, copied next to this file in the app as
`Contents/Resources/Licenses/`). The Mac app is a separate program from the Windows one and bundles less. This file lists
what the Mac app **contains or ships**, and what it only uses. The Windows list is in the repository's
`THIRD_PARTY_NOTICES.md`.

## Contained in the app

### libwebp 1.6.0 (WebP encoder and decoder, with libwebpmux and sharpyuv)

Used to write WebP files (ImageIO can only read them) and to put camera data into them. Compiled into the
PomeloO executable from the official sources, copied by `mac/scripts/vendor-libwebp.sh` into `mac/Sources/CWebP`
(the tag and commit are in `mac/Sources/CWebP/VERSION`).

- Project: https://github.com/webmproject/libwebp
- Licence: BSD-3-Clause, with Google's additional patent grant (`PATENTS`). Both files are shipped in the app as
  `Licenses/libwebp-COPYING.txt` and `Licenses/libwebp-PATENTS.txt`, with the list of contributors as
  `Licenses/libwebp-AUTHORS.txt`.

The licence text, as required for binary distribution:

```
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

```

### ffmpeg 9.0.2 (audio and video conversion) and the libraries inside it

Run as a separate program, `Contents/Resources/Tools/ffmpeg`, for the audio and video formats AVFoundation cannot
handle. It is **not** the Homebrew build: `mac/scripts/build-ffmpeg.sh` builds it from the projects' own release
sources, static, arm64 only, configured **without `--enable-gpl` and without `--enable-nonfree`**, so it is licensed
under the **LGPL-2.1-or-later**. The script fails if the binary reports anything else, links a library outside
macOS, or lacks or contains the wrong encoders. libx264 and libx265 (GPL) are not in it.

| Component | Version | Licence | Used for |
|---|---|---|---|
| FFmpeg | 9.0.2 | LGPL-2.1-or-later | decoders, encoders (aac, flac, PCM, GIF), muxers |
| LAME (libmp3lame) | 3.100 | LGPL-2.0-or-later | MP3 |
| Opus (libopus) | 1.6.1 | BSD-3-Clause | Opus and OGG audio |
| libvpx | 1.17.0 | BSD-3-Clause, with a patent grant | VP9 (WebM) |

Apple's VideoToolbox and AudioToolbox (H.264, HEVC, AAC) are used through macOS and are not redistributed.

- Sources: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz, https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz,
  https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz, https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz.
  The exact URLs, SHA-256 hashes and the `configure` line of the shipped binary are in
  `Contents/Resources/BUILD_INFO.txt`; the script that built it is `mac/scripts/build-ffmpeg.sh` in PomeloO's source
  (https://github.com/aarayhan/PomeloO). The ffmpeg and LAME sources are not modified.
- Licence texts shipped in the app, in `Licenses/`: `ffmpeg-COPYING.LGPLv2.1.txt`, `ffmpeg-COPYING.LGPLv3.txt`,
  `lame-COPYING.txt`, `opus-COPYING.txt`, `libvpx-LICENSE.txt`, `libvpx-PATENTS.txt`.
- Replacing it: because ffmpeg is a separate executable and not linked into PomeloO, anyone can build their own ffmpeg
  with the script (or any other) and put it in `Tools/` in place of the bundled one. The app's ad-hoc signature then
  has to be made again (`mac/scripts/make-app.sh`).
- The patent grants of the codecs above are not a promise that no patent applies to the formats themselves; PomeloO
  does not ship a licence for them.

## Used but not shipped

| Component | How it is used | Notes |
|---|---|---|
| Apple frameworks (ImageIO, Core Graphics, PDFKit, Vision, AVFoundation, Core Image, AppKit, SwiftUI) | Image, PDF, OCR and audio work | Part of macOS; nothing of them is redistributed |
| ffmpeg (Homebrew build) | Audio and video conversions, **local development and tests only** | **Never bundled.** The Homebrew build is GPL-3.0-or-later and links shared libraries from `/opt/homebrew`, so it cannot be shipped |
