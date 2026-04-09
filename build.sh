#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$ROOT/build/BatteryBar"
APP="$ROOT/dist/BatteryBar 7.3.app"

echo "Compiling BatteryBar V7.3..."
swiftc \
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

echo "Signing..."
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
