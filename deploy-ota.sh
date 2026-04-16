#!/bin/bash
# BatteryBar OTA Deploy — pull from GitHub, build on Mac, push update to icamel
set -e

MAC="naif@100.122.115.71"
PROJ_DIR="/home/ft/apps/MacApps/BatteryBar"
MAC_PROJ="~/apps/BatteryBar"
ICAMEL_DIR="/home/ft/apps/MacApps/icamel/web/product/batterybar"
SIGN_ID="Developer ID Application: Naif AlQazlan (9VRVCKY375)"
APP_NAME="BatteryBar"

echo "==> Pulling latest from GitHub..."
cd "$PROJ_DIR"
git fetch origin --tags
git stash 2>/dev/null || true
git pull --rebase origin main

VERSION=$(git tag --sort=-v:refname | head -1 | sed 's/^v//')
if [ -z "$VERSION" ]; then
    echo "ERROR: No version tag found"
    exit 1
fi
echo "  Version: $VERSION"

echo "==> Syncing to Mac via rsync..."
rsync -av --delete --exclude='.git' --exclude='build' --exclude='dist' --exclude='.DS_Store' \
  "$PROJ_DIR/" "$MAC:$MAC_PROJ/"

echo "==> Building on Mac..."
ssh "$MAC" "security unlock-keychain -p '989898' ~/Library/Keychains/login.keychain-db"
ssh "$MAC" "cd $MAC_PROJ/v1.1 && bash build.sh 2>&1 | tail -5"

echo "==> Notarizing..."
ssh "$MAC" "bash -s" << REMOTE
set -e
cd $MAC_PROJ/v1.1/dist
ditto -c -k --keepParent ${APP_NAME}.app /tmp/${APP_NAME}-notarize.zip
xcrun notarytool submit /tmp/${APP_NAME}-notarize.zip \
    --key ~/.appstore/AuthKey_A9C6Q7QRPY.p8 \
    --key-id A9C6Q7QRPY \
    --issuer f8bed33a-4194-4840-901c-beb0ed6c2817 \
    --wait
xcrun stapler staple ${APP_NAME}.app

# Create update zip (Sparkle uses zip not DMG)
rm -f /tmp/${APP_NAME}-update.zip
cd $MAC_PROJ/v1.1/dist && zip -r -y /tmp/${APP_NAME}-update.zip ${APP_NAME}.app

# Create DMG for website download
rm -f /tmp/${APP_NAME}.dmg
hdiutil create -volname "${APP_NAME}" -srcfolder ${APP_NAME}.app -ov -format UDZO /tmp/${APP_NAME}.dmg
security unlock-keychain -p '989898' ~/Library/Keychains/login.keychain-db
codesign --force --sign "$SIGN_ID" /tmp/${APP_NAME}.dmg

echo "Notarized & stapled"

# Sparkle sign (uses keychain-stored key)
SIGN_UPDATE="\$(find ~/apps/Swalfy -name sign_update -path '*/Sparkle/bin/*' 2>/dev/null | head -1)"
"\$SIGN_UPDATE" /tmp/${APP_NAME}-update.zip --ed-key-file ~/.batterybar/sparkle_ed25519_key.txt 2>&1
REMOTE

echo "==> Getting Sparkle signature..."
SIGN_LINE=$(ssh "$MAC" "SIGN_UPDATE=\$(find ~/apps/Swalfy -name sign_update -path '*/Sparkle/bin/*' 2>/dev/null | head -1) && \"\$SIGN_UPDATE\" /tmp/${APP_NAME}-update.zip 2>&1")
ED_SIG=$(echo "$SIGN_LINE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGN_LINE" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
echo "  Signature: $ED_SIG"
echo "  Length: $LENGTH"

if [ -z "$ED_SIG" ] || [ -z "$LENGTH" ]; then
    echo "ERROR: Failed to get Sparkle signature"
    exit 1
fi

echo "==> Deploying to icamel..."
scp "$MAC":/tmp/${APP_NAME}-update.zip /tmp/${APP_NAME}-update.zip
scp "$MAC":/tmp/${APP_NAME}.dmg /tmp/${APP_NAME}.dmg
cp /tmp/${APP_NAME}-update.zip "$ICAMEL_DIR/${APP_NAME}-${VERSION}.zip"
cp /tmp/${APP_NAME}.dmg "$ICAMEL_DIR/${APP_NAME}.dmg"

PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat > "$ICAMEL_DIR/appcast.xml" << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://icamel.app/product/batterybar/appcast.xml</link>
    <description>${APP_NAME} Updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://icamel.app/product/batterybar/${APP_NAME}-${VERSION}.zip"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        sparkle:edSignature="${ED_SIG}"
        length="${LENGTH}"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
APPCAST

echo ""
echo "✓ ${APP_NAME} v${VERSION} deployed to icamel"
