#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building Wattly in Release configuration..."
xcodebuild -scheme Wattly \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build

APP_PATH=".build/DerivedData/Build/Products/Release/Wattly.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Wattly.app not found at $APP_PATH" >&2
  exit 1
fi

if [ ! -x "$APP_PATH/Contents/Helpers/WattlyFanDaemon" ]; then
  echo "Error: Embedded WattlyFanDaemon helper missing or not executable in $APP_PATH/Contents/Helpers" >&2
  exit 1
fi

OUTPUT_DIR="build/Release"
mkdir -p "$OUTPUT_DIR"
ZIP_PATH="$OUTPUT_DIR/Wattly.zip"

echo "==> Creating $ZIP_PATH..."
rm -f "$ZIP_PATH"
(cd "$(dirname "$APP_PATH")" && zip -r -y "$ROOT_DIR/$ZIP_PATH" "$(basename "$APP_PATH")")

echo "==> Success! Release asset created at $ZIP_PATH"
