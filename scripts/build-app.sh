#!/usr/bin/env bash

set -euo pipefail

APP_NAME="ImmichMacApp"
BUNDLE_NAME="Immich"
BUNDLE_ID="app.immich.desktop.macos"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
OPEN_AFTER_BUILD=0

usage() {
  echo "Usage: $0 [--debug|--release] [--open] [--output <directory>]" >&2
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool not found: ${tool}" >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: ${path}" >&2
    exit 1
  fi
}

OUTPUT_ROOT=""

while (($# > 0)); do
  case "$1" in
    --debug)
      BUILD_CONFIGURATION="debug"
      ;;
    --release)
      BUILD_CONFIGURATION="release"
      ;;
    --open)
      OPEN_AFTER_BUILD=1
      ;;
    --output)
      shift
      if (($# == 0)); then
        usage
        exit 1
      fi
      OUTPUT_ROOT="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="${PROJECT_DIR}/.build/app"
fi

APP_BUNDLE="${OUTPUT_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICONSET_DIR="${OUTPUT_ROOT}/${APP_NAME}.iconset"
EXECUTABLE_PATH="${PROJECT_DIR}/.build/${BUILD_CONFIGURATION}/${APP_NAME}"
ICON_SOURCE="${REPO_DIR}/design/immich-logo.png"

for tool in node swift sips iconutil plutil codesign; do
  require_tool "$tool"
done

require_file "$ICON_SOURCE"
require_file "${REPO_DIR}/package.json"

VERSION="$(
  node -e 'const fs = require("node:fs"); const path = process.argv[1]; console.log(JSON.parse(fs.readFileSync(path, "utf8")).version);' \
    "${REPO_DIR}/package.json"
)"

mkdir -p "$OUTPUT_ROOT"

swift build \
  -c "$BUILD_CONFIGURATION" \
  --package-path "$PROJECT_DIR" \
  --product "$APP_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at ${EXECUTABLE_PATH}" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

cp "$EXECUTABLE_PATH" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

create_icon() {
  local size="$1"
  local filename="$2"
  sips -s format png -z "$size" "$size" "$ICON_SOURCE" --out "${ICONSET_DIR}/${filename}" >/dev/null
}

create_icon 16 "icon_16x16.png"
create_icon 32 "icon_16x16@2x.png"
create_icon 32 "icon_32x32.png"
create_icon 64 "icon_32x32@2x.png"
create_icon 128 "icon_128x128.png"
create_icon 256 "icon_128x128@2x.png"
create_icon 256 "icon_256x256.png"
create_icon 512 "icon_256x256@2x.png"
create_icon 512 "icon_512x512.png"
create_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "${RESOURCES_DIR}/${APP_NAME}.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${BUNDLE_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.photography</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

rm -rf "$ICONSET_DIR"

echo "Built app bundle: ${APP_BUNDLE}"

if ((OPEN_AFTER_BUILD)); then
  open "$APP_BUNDLE"
fi
