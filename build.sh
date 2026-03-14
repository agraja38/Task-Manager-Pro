#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TaskManagerPro"
DISPLAY_NAME="Task Manager Pro"
DIST_DIR="$ROOT_DIR/dist"
VERSION="1.0.01"
BUILD_NUMBER="101"
ARM_BIN="$DIST_DIR/${APP_NAME}-arm64"
X64_BIN="$DIST_DIR/${APP_NAME}-x86_64"
ICONSET_DIR="$ROOT_DIR/${APP_NAME}.iconset"
ICNS_PATH="$DIST_DIR/${APP_NAME}.icns"
APPLE_SILICON_DIR="$DIST_DIR/apple-silicon"
INTEL_DIR="$DIST_DIR/intel"
APPLE_SILICON_APP="$APPLE_SILICON_DIR/${DISPLAY_NAME}.app"
INTEL_APP="$INTEL_DIR/${DISPLAY_NAME}.app"
APPLE_SILICON_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-apple-silicon.zip"
INTEL_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-intel.zip"
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

ditto -c -k --keepParent --norsrc "$APPLE_SILICON_APP" "$APPLE_SILICON_ZIP"
ditto -c -k --keepParent --norsrc "$INTEL_APP" "$INTEL_ZIP"

if [[ "$(uname -m)" == "arm64" ]]; then
  cp -R "$APPLE_SILICON_APP" "$HOST_APP"
else
  cp -R "$INTEL_APP" "$HOST_APP"
fi

cat > "$ROOT_DIR/docs/update.json" <<'JSON'
{
  "version": "1.0.01",
  "build": 101,
  "notes": "Fix live process loading, streamline the interface, improve updater behavior, and ship separate Apple Silicon and Intel downloads with the new icon.",
  "arm64AssetURL": "https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.01/TaskManagerPro-1.0.01-apple-silicon.zip",
  "x86_64AssetURL": "https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.01/TaskManagerPro-1.0.01-intel.zip"
}
JSON

echo "Built host app: $HOST_APP"
echo "Built Apple Silicon zip: $APPLE_SILICON_ZIP"
echo "Built Intel zip: $INTEL_ZIP"
