#!/usr/bin/env bash
# Packs PomeloO.app into mac/build/PomeloO-Mac-VERSION.dmg (compressed UDZO image).
#
#   mac/scripts/make-dmg.sh VERSION [APP_PATH]
#
#   VERSION   X.Y.Z, the number in the mac-vX.Y.Z tag
#   APP_PATH  default: mac/build/PomeloO.app (made by make-app.sh)
#
# Environment: OUT_DIR (default mac/build). Touches nothing outside mac/ unless OUT_DIR says so.
# The image holds PomeloO.app and a symlink to /Applications, so the user drags one onto the other.
# The app is copied with ditto, which keeps its signature intact.
set -euo pipefail

MAC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "make-dmg: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: make-dmg.sh VERSION [APP_PATH]"
VERSION=$1
OUT_DIR=${OUT_DIR:-$MAC_DIR/build}
APP=${2:-$OUT_DIR/PomeloO.app}

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3, got '$VERSION'"
[[ -d $APP ]] || fail "app not found: $APP (run make-app.sh first)"
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "$APP has no valid signature (run make-app.sh again)"

DMG=$OUT_DIR/PomeloO-Mac-$VERSION.dmg
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pomeloo-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/PomeloO.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "PomeloO" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null || fail "hdiutil verify failed for $DMG"

echo "make-dmg: OK $DMG"
shasum -a 256 "$DMG"
