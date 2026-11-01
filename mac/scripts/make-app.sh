#!/usr/bin/env bash
# Builds PomeloO.app from an already-built arm64 executable, signs it ad-hoc and verifies the signature.
#
#   mac/scripts/make-app.sh EXECUTABLE VERSION [RESOURCES_DIR]
#
#   EXECUTABLE     the built Mach-O binary (arm64); it becomes Contents/MacOS/PomeloO
#   VERSION        X.Y.Z, the number in the mac-vX.Y.Z tag
#   RESOURCES_DIR  optional; copied to Contents/Resources (put AppIcon.icns there for the app icon)
#
# Environment (all optional):
#   OUT_DIR         where PomeloO.app is written          (default: mac/build)
#   BUNDLE_ID       CFBundleIdentifier                    (default: app.pomeloo.mac, an assumption)
#   MIN_MACOS       LSMinimumSystemVersion                (default: 13.0, an assumption)
#   MENU_BAR_ONLY   1 = no Dock icon (LSUIElement)        (default: 1, an assumption)
#
# Order matters. An ad-hoc signature seals Info.plist and everything under Contents/, so the
# signature is made LAST, after Info.plist and the resources are in place. Changing anything inside
# the .app afterwards breaks the seal: run this script again instead of editing the bundle.
set -euo pipefail

MAC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "make-app: $*" >&2; exit 1; }

[[ $# -ge 2 && $# -le 3 ]] || fail "usage: make-app.sh EXECUTABLE VERSION [RESOURCES_DIR]"
EXE=$1
VERSION=$2
RESOURCES=${3:-}
OUT_DIR=${OUT_DIR:-$MAC_DIR/build}
BUNDLE_ID=${BUNDLE_ID:-app.pomeloo.mac}
MIN_MACOS=${MIN_MACOS:-13.0}
MENU_BAR_ONLY=${MENU_BAR_ONLY:-1}

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3, got '$VERSION'"
[[ -f $EXE ]] || fail "executable not found: $EXE"
[[ -z $RESOURCES || -d $RESOURCES ]] || fail "resources directory not found: $RESOURCES"
lipo -archs "$EXE" | grep -qw arm64 || fail "$EXE has no arm64 slice (Apple Silicon only): $(lipo -archs "$EXE")"

APP=$OUT_DIR/PomeloO.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. executable
cp "$EXE" "$APP/Contents/MacOS/PomeloO"
chmod 755 "$APP/Contents/MacOS/PomeloO"

# 2. resources
if [[ -n $RESOURCES ]]; then
    ditto "$RESOURCES" "$APP/Contents/Resources"
fi

# 3. Info.plist (after the resources, so the icon key can follow what is really there)
ICON_KEY=""
if [[ -f $APP/Contents/Resources/AppIcon.icns ]]; then
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi
UIELEMENT="<false/>"
[[ $MENU_BAR_ONLY == 1 ]] && UIELEMENT="<true/>"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>PomeloO</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PomeloO</string>
    <key>CFBundleDisplayName</key><string>PomeloO</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key>$UIELEMENT
    <key>NSHighResolutionCapable</key><true/>
$ICON_KEY
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "generated Info.plist is not valid"

# 4. ad-hoc signature, last. Extended attributes (Finder info, resource forks) make codesign refuse.
xattr -cr "$APP"
# nested code first (inside-out), then the app itself
while IFS= read -r -d '' nested; do
    codesign --force --sign - "$nested"
done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' \) -print0)
# Helper programs such as Resources/Tools/ffmpeg: the app's own signature only seals them as data, and
# arm64 macOS will not run a Mach-O file that carries no signature of its own.
if [[ -d $APP/Contents/Resources/Tools ]]; then
    while IFS= read -r -d '' helper; do
        if file -b "$helper" | grep -q 'Mach-O'; then
            codesign --force --sign - "$helper"
        fi
    done < <(find "$APP/Contents/Resources/Tools" -type f -perm -u+x -print0)
fi
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# 5. verification
echo "--- codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "signature does not verify"
echo "--- codesign -dv"
INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
echo "$INFO"
grep -qx 'Signature=adhoc' <<<"$INFO" || fail "expected Signature=adhoc"
grep -q '^Info.plist entries=' <<<"$INFO" || fail "Info.plist is not sealed into the signature"
echo "make-app: OK $APP (version $VERSION, ad-hoc signed, not notarized)"
