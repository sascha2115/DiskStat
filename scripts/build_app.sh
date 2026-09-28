#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DiskStat"
BUNDLE_ID="com.sascha.diskstat"
# The human-facing version is whatever the most recent tag says, so the tag and
# the bundle cannot drift apart. Bump the version by tagging, not by editing
# this file -- a hardcoded constant is what left the app reporting "1.0"
# through 24 commits.
if VERSION_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
    VERSION="${VERSION_TAG#v}"
else
    VERSION="0.0.0-dev"
fi
# Build number tracks the commit count so builds are distinguishable.
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
ICON_PNG="$ROOT_DIR/Sources/icon/AppIcon.png"
ICON_ICNS_NAME="DiskStat.icns"

cd "$ROOT_DIR"

swift build -c release

APP_DIR="$ROOT_DIR/Dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY_SRC="$ROOT_DIR/.build/release/diskstat"
BINARY_DST="$MACOS_DIR/${APP_NAME}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"

if [[ -f "$ICON_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    ICONSET_DIR="$ROOT_DIR/.build/${APP_NAME}.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    # Generate the standard macOS iconset from the 1024x1024 source PNG.
    for size in 16 32 64 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        size2=$((size * 2))
        sips -z "$size2" "$size2" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/$ICON_ICNS_NAME"
else
    echo "Warning: icon generation skipped (missing $ICON_PNG, sips, or iconutil)"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_ICNS_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    # Sign the nested binary first and the bundle second. `--deep` is
    # discouraged by Apple because it signs nested code indiscriminately; here
    # there is exactly one nested item worth signing.
    codesign --force --sign - "$MACOS_DIR/$APP_NAME" >/dev/null 2>&1 || true
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app bundle at: $APP_DIR"
