#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$ROOT/build/BatteryBar"
APP="$ROOT/dist/BatteryBar.app"
IDENTITY="Developer ID Application: Naif AlQazlan (9VRVCKY375)"

echo "Compiling BatteryBar..."
SDK=$(xcrun --show-sdk-path --sdk macosx)
swiftc -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -O \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  -framework WebKit \
  -framework IOBluetooth \
  "$ROOT"/Sources/*.swift \
  -o "$EXECUTABLE"

echo "Packaging app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/BatteryBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Copy app icon
ICON="$ROOT/../icon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/icon.icns"
fi

echo "Signing with hardened runtime..."
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "Done: $APP"
