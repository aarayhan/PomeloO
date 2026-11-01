#!/usr/bin/env bash
# Copies the parts of libwebp that PomeloO compiles from the official repository into mac/Sources/CWebP.
#
#   mac/scripts/vendor-libwebp.sh [TAG]        default: v1.6.0
#
# libwebp (BSD-3-Clause, with its patent grant) has no Swift package of its own, and a wrapper package
# from someone else would put their copy of the code between PomeloO and Google's. The tag and the commit
# that were copied are written to Sources/CWebP/VERSION. Run this again to move to another release, then
# run the tests.
set -euo pipefail

TAG=${1:-v1.6.0}
MAC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEST=$MAC_DIR/Sources/CWebP
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pomeloo-libwebp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/webmproject/libwebp "$WORK/libwebp"
SRC=$WORK/libwebp
COMMIT=$(git -C "$SRC" rev-parse HEAD)

rm -rf "$DEST"
mkdir -p "$DEST/src" "$DEST/sharpyuv"
# decoder, encoder, DSP (every CPU variant: each file switches itself off where it does not apply),
# utilities, the mux (for EXIF and colour profiles) and the public headers (src/webp)
for dir in dec dsp enc utils mux webp; do
    cp -R "$SRC/src/$dir" "$DEST/src/$dir"
done
cp "$SRC"/sharpyuv/*.c "$SRC"/sharpyuv/*.h "$DEST/sharpyuv/"
cp "$SRC/COPYING" "$SRC/PATENTS" "$SRC/AUTHORS" "$DEST/"
echo "libwebp $TAG ($COMMIT) from https://github.com/webmproject/libwebp" > "$DEST/VERSION"

echo "vendor-libwebp: $TAG ($COMMIT)"
echo "  $(find "$DEST" -name '*.c' | wc -l | tr -d ' ') C files, $(du -sk "$DEST" | cut -f1) KB in $DEST"
