#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PulseTaskManager"
DISPLAY_NAME="PulseTask Manager"
APP_DIR="$ROOT_DIR/${DISPLAY_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DIST_DIR="$ROOT_DIR/dist"
ARM_BIN="$DIST_DIR/${APP_NAME}-arm64"
X64_BIN="$DIST_DIR/${APP_NAME}-x86_64"
UNIVERSAL_BIN="$MACOS_DIR/$APP_NAME"
ZIP_PATH="$DIST_DIR/${APP_NAME}-1.0.0.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}-1.0.0.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"

rm -rf "$APP_DIR" "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DIST_DIR"
cp "$ROOT_DIR/AppBundle/Contents/Info.plist" "$CONTENTS_DIR/Info.plist"

COMMON_FLAGS=(
  -parse-as-library
  -framework AppKit
  -framework SwiftUI
  -framework Charts
  -framework IOKit
  -framework ServiceManagement
)

SOURCE_FILES=("${(@f)$(find "$ROOT_DIR/Sources" -name '*.swift' -print | sort)}")

swiftc -target arm64-apple-macos13.0 "${COMMON_FLAGS[@]}" "${SOURCE_FILES[@]}" -o "$ARM_BIN"
swiftc -target x86_64-apple-macos13.0 "${COMMON_FLAGS[@]}" "${SOURCE_FILES[@]}" -o "$X64_BIN"
lipo -create "$ARM_BIN" "$X64_BIN" -output "$UNIVERSAL_BIN"
chmod +x "$UNIVERSAL_BIN"

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

cat > "$ROOT_DIR/docs/update.json" <<'JSON'
{
  "version": "1.0.0",
  "build": 1,
  "notes": "Initial release of PulseTask Manager.",
  "assetURL": "https://github.com/agraja38/pulse-task-manager-macos/releases/download/v1.0.0/PulseTaskManager-1.0.0.zip"
}
JSON

echo "Built app: $APP_DIR"
echo "Built zip: $ZIP_PATH"
echo "Built dmg: $DMG_PATH"
