#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/BatteryBar.app"
SPARKLE_BIN="/Users/naif/apps/BookmarkHub/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
SERVER="ft@134.195.199.64"
REMOTE_DIR="/var/www/icamel.app/product/batterybar"
DOWNLOAD_URL="https://icamel.app/product/batterybar/BatteryBar.zip"

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)

echo "Deploying BatteryBar v$VERSION (build $BUILD)..."

# Create ZIP for distribution
echo "Creating ZIP..."
cd "$ROOT/dist"
rm -f BatteryBar.zip
ditto -c -k --keepParent "BatteryBar.app" BatteryBar.zip
ZIP_SIZE=$(stat -f%z BatteryBar.zip)

# Sign the ZIP with Sparkle EdDSA
echo "Signing with EdDSA..."
SIGNATURE=$("$SPARKLE_BIN/sign_update" BatteryBar.zip)
echo "  Signature: $SIGNATURE"

# Generate appcast.xml
echo "Generating appcast.xml..."
cat > "$ROOT/dist/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>BatteryBar</title>
    <link>https://icamel.app/product/batterybar/appcast.xml</link>
    <description>BatteryBar Updates</description>
    <language>en</language>
    <item>
      <title>BatteryBar v$VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $SIGNATURE
                 length="$ZIP_SIZE" />
    </item>
  </channel>
</rss>
EOF

echo "Appcast generated."

# Upload to server
echo "Uploading to $SERVER:$REMOTE_DIR..."
ssh "$SERVER" "mkdir -p $REMOTE_DIR"
scp "$ROOT/dist/BatteryBar.zip" "$SERVER:$REMOTE_DIR/"
scp "$ROOT/dist/appcast.xml" "$SERVER:$REMOTE_DIR/"

echo ""
echo "Deployed:"
echo "  App:     $DOWNLOAD_URL"
echo "  Appcast: https://icamel.app/product/batterybar/appcast.xml"
echo "  Version: $VERSION (build $BUILD)"
