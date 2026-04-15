#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$ROOT/build/BatteryBar"
APP="$ROOT/dist/BatteryBar.app"
IDENTITY="Developer ID Application: Naif AlQazlan (9VRVCKY375)"
SPARKLE_XCFW="/Users/naif/apps/BookmarkHub/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
SPARKLE_FW="$SPARKLE_XCFW/Sparkle.framework"

echo "Compiling BatteryBar..."
SDK=$(xcrun --show-sdk-path --sdk macosx)
swiftc -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -F "$SPARKLE_XCFW" \
  -O \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  -framework WebKit \
  -framework IOBluetooth \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT"/Sources/*.swift \
  "$ROOT"/Sources/BigInt/*.swift \
  -o "$EXECUTABLE"

echo "Packaging app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
cp "$EXECUTABLE" "$APP/Contents/MacOS/BatteryBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Copy app icon
ICON="$ROOT/../icon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/icon.icns"
fi

# Embed Sparkle framework
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

echo "Signing Sparkle internals..."
FRAMEWORKS_DIR="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FRAMEWORKS_DIR/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FRAMEWORKS_DIR/Versions/B/Updater.app" 2>/dev/null || true
find "$FRAMEWORKS_DIR/Versions/B/XPCServices" -name "*.xpc" -exec codesign --force --options runtime --timestamp --sign "$IDENTITY" {} \; 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FRAMEWORKS_DIR" 2>/dev/null || true

echo "Signing app..."
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "Done: $APP"
