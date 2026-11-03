#!/usr/bin/env bash
# Builds the ffmpeg that ships inside PomeloO.app: static, arm64, LGPL (no --enable-gpl, no --enable-nonfree),
# from the projects' own release sources, with a fixed set of encoders.
#
#   mac/scripts/build-ffmpeg.sh [OUT_DIR]        default: mac/build/ffmpeg
#
# Result (OUT_DIR):
#   Tools/ffmpeg        the executable; give OUT_DIR to make-app.sh as its third argument
#   Licenses/           licence texts of ffmpeg and of every library linked into it
#   BUILD_INFO.txt      versions, source hashes and the configure line
#
# Encoders: h264_videotoolbox, hevc_videotoolbox (Apple hardware), libvpx-vp9, libopus, libmp3lame, and ffmpeg's own
# aac, flac, PCM and GIF. libx264 and libx265 are GPL and are NOT included. The list is checked at the end, and
# the build fails if an encoder is missing or if the licence is not LGPL.
#
# Needs: Xcode command line tools, make, curl, shasum and pkg-config (brew install pkgconf; only a build tool,
# nothing of it is bundled). nasm is not needed on arm64. Nothing outside OUT_DIR and a work directory is touched.
# Environment: JOBS (default: CPU count), WORK_DIR (default: a temporary directory, removed afterwards),
# KEEP_WORK=1 keeps it, SOURCES_DIR (default: mac/build/ffmpeg-sources) caches the downloaded tarballs.
#
# Sources are checked against the SHA-256 below. ffmpeg, libvpx and lame hashes were taken from the first
# download over HTTPS on 2026-11-01 (the projects publish no hash list next to the file; ffmpeg publishes a GPG
# signature, which this script does not check because gpg is not installed here); opus' hash matches the
# SHA256SUMS.txt on downloads.xiph.org. Moving to another version means updating both lines.
set -euo pipefail

MAC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "build-ffmpeg: $*" >&2; exit 1; }
log() { echo "build-ffmpeg: $*" >&2; }

FFMPEG_VERSION=9.0.2
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

OPUS_VERSION=1.6.1
OPUS_URL=https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

LAME_VERSION=3.100
LAME_URL=https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e

VPX_VERSION=1.17.0
VPX_URL=https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VERSION.tar.gz
VPX_SHA256=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a

MIN_MACOS=${MIN_MACOS:-13.0}
OUT=${1:-$MAC_DIR/build/ffmpeg}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
SOURCES=${SOURCES_DIR:-$MAC_DIR/build/ffmpeg-sources}

[[ $(uname -m) == arm64 ]] || fail "run this on Apple Silicon (arm64)"
for tool in make curl shasum pkg-config clang tar; do
    command -v "$tool" >/dev/null || fail "missing build tool: $tool$([[ $tool == pkg-config ]] && echo ' (brew install pkgconf)')"
done

WORK=${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/pomeloo-ffmpeg.XXXXXX")}
mkdir -p "$WORK" "$SOURCES"
[[ ${KEEP_WORK:-0} == 1 ]] || trap 'rm -rf "$WORK"' EXIT
PREFIX=$WORK/prefix
mkdir -p "$PREFIX"

# Nothing from Homebrew or MacPorts may leak in: only the system and the prefix above are searched.
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
export CC=clang
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$MIN_MACOS -fPIC"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v pkg-config)")

fetch() { # name url sha256 -> path of the verified tarball
    local file=$SOURCES/$(basename "$2")
    if [[ ! -f $file ]]; then
        log "downloading $2"
        curl -fsSL --retry 3 -o "$file.part" "$2" && mv "$file.part" "$file"
    fi
    local actual
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    [[ $actual == "$3" ]] || { rm -f "$file"; fail "$1: SHA-256 is $actual, expected $3 (file removed)"; }
    echo "$file"
}

unpack() { # tarball -> directory (named by the first entry of the archive: GitHub names the file v1.2.3 but the folder libvpx-1.2.3)
    mkdir -p "$WORK/src"
    local top
    top=$(tar -tf "$1" | head -1 | cut -d/ -f1)
    tar -xf "$1" -C "$WORK/src"
    echo "$WORK/src/$top"
}

T0=$SECONDS
step() { log "[$(( (SECONDS - T0) / 60 )) min] $*"; }

# --- libmp3lame (LGPL-2.0+)
step "lame $LAME_VERSION"
LAME=$(unpack "$(fetch lame "$LAME_URL" "$LAME_SHA256")")
(cd "$LAME" \
    && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend --disable-decoder \
        --disable-gtktest --disable-dependency-tracking >"$WORK/lame.log" 2>&1 \
    && make -j"$JOBS" >>"$WORK/lame.log" 2>&1 && make install >>"$WORK/lame.log" 2>&1) \
    || { tail -30 "$WORK/lame.log"; fail "lame failed"; }

# --- libopus (BSD-3-Clause)
step "opus $OPUS_VERSION"
OPUS=$(unpack "$(fetch opus "$OPUS_URL" "$OPUS_SHA256")")
(cd "$OPUS" \
    && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-doc --disable-extra-programs \
        --disable-dependency-tracking >"$WORK/opus.log" 2>&1 \
    && make -j"$JOBS" >>"$WORK/opus.log" 2>&1 && make install >>"$WORK/opus.log" 2>&1) \
    || { tail -30 "$WORK/opus.log"; fail "opus failed"; }

# --- libvpx (BSD-3-Clause)
step "libvpx $VPX_VERSION"
VPX=$(unpack "$(fetch libvpx "$VPX_URL" "$VPX_SHA256")")
DARWIN=$(uname -r | cut -d. -f1)
(cd "$VPX" \
    && ./configure --prefix="$PREFIX" --target="arm64-darwin$DARWIN-gcc" --enable-vp8 --enable-vp9 \
        --disable-shared --enable-static --enable-pic --enable-runtime-cpu-detect \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests >"$WORK/vpx.log" 2>&1 \
    && make -j"$JOBS" >>"$WORK/vpx.log" 2>&1 && make install >>"$WORK/vpx.log" 2>&1) \
    || { tail -30 "$WORK/vpx.log"; fail "libvpx failed"; }

# --- ffmpeg (LGPL-2.1+ as configured here)
step "ffmpeg $FFMPEG_VERSION"
FFMPEG=$(unpack "$(fetch ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256")")
# --disable-autodetect: only what is listed below is linked, so a library that happens to be installed on the
# build machine can never end up in the binary.
CONFIGURE=(
    --prefix="$PREFIX/ffmpeg" --arch=arm64 --cc=clang
    --extra-cflags="-I$PREFIX/include -mmacosx-version-min=$MIN_MACOS"
    --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=$MIN_MACOS"
    --enable-static --disable-shared --enable-pic
    --disable-autodetect
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib
    --enable-libmp3lame --enable-libopus --enable-libvpx
    --disable-debug --disable-doc --disable-ffplay --disable-ffprobe
    --disable-network --disable-sdl2
)
(cd "$FFMPEG" \
    && ./configure "${CONFIGURE[@]}" >"$WORK/ffmpeg.log" 2>&1 \
    && make -j"$JOBS" >>"$WORK/ffmpeg.log" 2>&1 && make install >>"$WORK/ffmpeg.log" 2>&1) \
    || { tail -40 "$WORK/ffmpeg.log"; fail "ffmpeg failed"; }

BIN=$PREFIX/ffmpeg/bin/ffmpeg
step "checking the result"

# 1. licence: LGPL, never GPL or nonfree
VERSION_TEXT=$("$BIN" -version)
grep -q -- '--enable-gpl' <<<"$VERSION_TEXT" && fail "the build was configured with --enable-gpl"
grep -q -- '--enable-nonfree' <<<"$VERSION_TEXT" && fail "the build was configured with --enable-nonfree"
LICENSE_TEXT=$("$BIN" -hide_banner -L 2>&1 | head -4)
grep -qi "Lesser General Public" <<<"$LICENSE_TEXT" || fail "ffmpeg does not report the LGPL: $LICENSE_TEXT"

# 2. architecture and what it links
lipo -archs "$BIN" | grep -qx arm64 || fail "not a pure arm64 binary: $(lipo -archs "$BIN")"
BAD=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)
[[ -z $BAD ]] || fail "links libraries outside the system: $BAD"

# 3. encoders: all wanted ones present, no GPL ones
ENCODERS=$("$BIN" -hide_banner -encoders)
for enc in h264_videotoolbox hevc_videotoolbox libvpx-vp9 libopus libmp3lame aac flac pcm_s16le gif; do
    grep -qE " $enc( |$)" <<<"$ENCODERS" || fail "encoder missing: $enc"
done
for enc in libx264 libx265 libfdk_aac; do
    ! grep -qE " $enc( |$)" <<<"$ENCODERS" || fail "encoder that must not be there: $enc"
done

# --- output
rm -rf "$OUT"
mkdir -p "$OUT/Tools" "$OUT/Licenses"
cp "$BIN" "$OUT/Tools/ffmpeg"
cp "$FFMPEG/COPYING.LGPLv2.1" "$OUT/Licenses/ffmpeg-COPYING.LGPLv2.1.txt"
cp "$FFMPEG/COPYING.LGPLv3" "$OUT/Licenses/ffmpeg-COPYING.LGPLv3.txt"
cp "$LAME/COPYING" "$OUT/Licenses/lame-COPYING.txt"
cp "$OPUS/COPYING" "$OUT/Licenses/opus-COPYING.txt"
cp "$VPX/LICENSE" "$OUT/Licenses/libvpx-LICENSE.txt"
cp "$VPX/PATENTS" "$OUT/Licenses/libvpx-PATENTS.txt"
{
    echo "ffmpeg $FFMPEG_VERSION  $FFMPEG_URL  sha256 $FFMPEG_SHA256"
    echo "lame $LAME_VERSION  $LAME_URL  sha256 $LAME_SHA256"
    echo "opus $OPUS_VERSION  $OPUS_URL  sha256 $OPUS_SHA256"
    echo "libvpx $VPX_VERSION  $VPX_URL  sha256 $VPX_SHA256"
    echo "built with $(clang --version | head -1), macOS SDK $(xcrun --show-sdk-version), deployment target $MIN_MACOS"
    echo "configure: ${CONFIGURE[*]}"
    echo
    echo "$VERSION_TEXT"
} >"$OUT/BUILD_INFO.txt"

SIZE=$(du -k "$OUT/Tools/ffmpeg" | cut -f1)
log "OK $OUT/Tools/ffmpeg (${SIZE} KB, $(( (SECONDS - T0) / 60 )) min). Next: make-app.sh EXE VERSION $OUT"
