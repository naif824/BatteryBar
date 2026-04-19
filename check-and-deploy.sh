#!/bin/bash
# BatteryBar — check GitHub for new tags, deploy OTA if new version found
set -e

PROJ_DIR="/home/ft/apps/high/MacApps/BatteryBar"
DEPLOYED_FILE="$PROJ_DIR/.last-deployed-version"
LOG="/home/ft/tools/logs/batterybar-deploy.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

LATEST_TAG=$(gh api repos/naif824/BatteryBar/tags --jq '.[0].name' 2>/dev/null)
if [ -z "$LATEST_TAG" ]; then
    log "ERROR: Failed to fetch tags"
    exit 1
fi

LATEST_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//')

DEPLOYED_VERSION=""
if [ -f "$DEPLOYED_FILE" ]; then
    DEPLOYED_VERSION=$(cat "$DEPLOYED_FILE")
fi

if [ "$LATEST_VERSION" = "$DEPLOYED_VERSION" ]; then
    log "No new version. Current: $DEPLOYED_VERSION"
    exit 0
fi

log "New version found: $LATEST_VERSION (was: $DEPLOYED_VERSION). Deploying..."

cd "$PROJ_DIR"
if bash deploy-ota.sh >> "$LOG" 2>&1; then
    echo "$LATEST_VERSION" > "$DEPLOYED_FILE"
    log "SUCCESS: Deployed v$LATEST_VERSION"
else
    log "ERROR: Deploy failed for v$LATEST_VERSION"
    exit 1
fi
