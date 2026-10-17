#!/bin/bash
# Builds Nanflow.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product nanflow

APP_DIR="build/Nanflow.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
cp "$BIN/nanflow" "$APP_DIR/Contents/MacOS/Nanflow"

cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"

# Copy .env inside the bundle directory so the app finds it (also reads ~/.nanflow/.env and ~/Library/Application Support/Nanflow/.env)
[ -f .env ] && cp .env "$APP_DIR/Contents/Resources/.env" || true

# Firmar con identidad estable (para que TCC recuerde los permisos entre builds)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Nanflow Dev"; then
	codesign --force --deep --sign "Nanflow Dev" "$APP_DIR" 2>/dev/null || codesign --force --sign - "$APP_DIR" 2>/dev/null || true
else
	codesign --force --sign - "$APP_DIR" 2>/dev/null || true
fi

echo "Built: $APP_DIR"
