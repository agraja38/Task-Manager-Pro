#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TaskManagerPro"
DISPLAY_NAME="Task Manager Pro"
DIST_DIR="$ROOT_DIR/dist"
VERSION="1.0.03"
BUILD_NUMBER="103"
ARM_BIN="$DIST_DIR/${APP_NAME}-arm64"
X64_BIN="$DIST_DIR/${APP_NAME}-x86_64"
ICONSET_DIR="$ROOT_DIR/${APP_NAME}.iconset"
ICNS_PATH="$DIST_DIR/${APP_NAME}.icns"
APPLE_SILICON_DIR="$DIST_DIR/apple-silicon"
INTEL_DIR="$DIST_DIR/intel"
APPLE_SILICON_APP="$APPLE_SILICON_DIR/${DISPLAY_NAME}.app"
INTEL_APP="$INTEL_DIR/${DISPLAY_NAME}.app"
APPLE_SILICON_DMG="$DIST_DIR/${APP_NAME}-${VERSION}-apple-silicon.dmg"
INTEL_DMG="$DIST_DIR/${APP_NAME}-${VERSION}-intel.dmg"
APPLE_SILICON_STAGE="$DIST_DIR/apple-silicon-dmg"
INTEL_STAGE="$DIST_DIR/intel-dmg"
HOST_APP="$ROOT_DIR/${DISPLAY_NAME}.app"

rm -rf "$DIST_DIR" "$HOST_APP" "$ICONSET_DIR"
mkdir -p "$DIST_DIR"

COMMON_FLAGS=(
  -parse-as-library
  -framework AppKit
  -framework SwiftUI
  -framework Charts
  -framework IOKit
  -framework ServiceManagement
)

SOURCE_FILES=("${(@f)$(find "$ROOT_DIR/Sources" -name '*.swift' -print | sort)}")

swift "$ROOT_DIR/generate_icon.swift"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

swiftc -target arm64-apple-macos13.0 "${COMMON_FLAGS[@]}" "${SOURCE_FILES[@]}" -o "$ARM_BIN"
swiftc -target x86_64-apple-macos13.0 "${COMMON_FLAGS[@]}" "${SOURCE_FILES[@]}" -o "$X64_BIN"

create_app_bundle() {
  local bin_path="$1"
  local app_path="$2"
  local contents_dir="$app_path/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  mkdir -p "$macos_dir" "$resources_dir"
  cp "$ROOT_DIR/AppBundle/Contents/Info.plist" "$contents_dir/Info.plist"
  cp "$bin_path" "$macos_dir/$APP_NAME"
  chmod +x "$macos_dir/$APP_NAME"
  cp "$ICNS_PATH" "$resources_dir/${APP_NAME}.icns"
}

create_app_bundle "$ARM_BIN" "$APPLE_SILICON_APP"
create_app_bundle "$X64_BIN" "$INTEL_APP"

build_dmg() {
  local app_path="$1"
  local stage_dir="$2"
  local dmg_path="$3"
  mkdir -p "$stage_dir"
  cp -R "$app_path" "$stage_dir/"
  ln -s /Applications "$stage_dir/Applications"
  hdiutil create -volname "$(basename "$dmg_path" .dmg)" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path" >/dev/null
}

build_dmg "$APPLE_SILICON_APP" "$APPLE_SILICON_STAGE" "$APPLE_SILICON_DMG"
build_dmg "$INTEL_APP" "$INTEL_STAGE" "$INTEL_DMG"

if [[ "$(uname -m)" == "arm64" ]]; then
  cp -R "$APPLE_SILICON_APP" "$HOST_APP"
else
  cp -R "$INTEL_APP" "$HOST_APP"
fi

cat > "$ROOT_DIR/docs/update.json" <<'JSON'
{
  "version": "1.0.03",
  "build": 103,
  "notes": "Switch installer media to classic drag-and-drop DMGs for both Apple Silicon and Intel Macs.",
  "arm64AssetURL": "https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.03/TaskManagerPro-1.0.03-apple-silicon.dmg",
  "x86_64AssetURL": "https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.03/TaskManagerPro-1.0.03-intel.dmg"
}
JSON

echo "Built host app: $HOST_APP"
echo "Built Apple Silicon dmg: $APPLE_SILICON_DMG"
echo "Built Intel dmg: $INTEL_DMG"
