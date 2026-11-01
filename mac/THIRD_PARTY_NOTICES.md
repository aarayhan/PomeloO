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

## Used but not shipped

| Component | How it is used | Notes |
|---|---|---|
| Apple frameworks (ImageIO, Core Graphics, PDFKit, Vision, AVFoundation, Core Image, AppKit, SwiftUI) | Image, PDF, OCR and audio work | Part of macOS; nothing of them is redistributed |
| ffmpeg (Homebrew build) | Audio and video conversions, **local development and tests only** | **Never bundled.** The Homebrew build is GPL-3.0-or-later and links shared libraries from `/opt/homebrew`, so it cannot be shipped |

## Planned, not in the app yet

- **ffmpeg** (a static arm64 build made from the official sources, without `--enable-gpl`, with the encoders listed in
  `mac/CLAUDE.md`) and the encoder libraries it links: its entry, with the licence of each library (LGPL parts
  need their own notice and a way to relink), is added in the same change that adds the build script. Until then the app
  carries no ffmpeg and offers no conversion that needs one.
