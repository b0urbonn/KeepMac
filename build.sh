#!/bin/bash
set -euo pipefail

# KeepMac build script — compiles the SwiftUI app, bundles KeepMac.app, and
# produces KeepMac.dmg in dist/. Requires Command Line Tools (xcode-select).

cd "$(dirname "$0")"

APP_NAME="KeepMac"
VERSION="1.1.0"
DIST="dist"
BUILD="build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

echo "==> Compiling KeepMac (swiftc, target $TARGET)"
mkdir -p "$BUILD"
swiftc -O -whole-module-optimization \
    -sdk "$SDK" \
    -target "$TARGET" \
    -module-name KeepMac \
    -parse-as-library \
    Sources/*.swift \
    -o "$BUILD/$APP_NAME"

echo "==> Generating app icon"
swift Tools/gen_icon.swift "$BUILD/icon_1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    s2=$((s * 2))
    sips -z "$s2" "$s2" "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "==> Bundling $APP_NAME.app"
APP_DIR="$DIST/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP_DIR"

echo "==> Creating DMG"
STAGE="$BUILD/dmg_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "Done:"
echo "  App : $APP_DIR"
echo "  DMG : $DMG"
echo ""
echo "Install: open the DMG and drag KeepMac to Applications."
