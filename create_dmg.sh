#!/bin/bash
set -euo pipefail

DMG_NAME="xTC-v0.6.dmg"
APP_PATH="./build/xTC.app"
TEMP_DMG="/tmp/xTC-temp.dmg"
MOUNT_POINT="/tmp/xTC-mount"
FINAL_DMG="./build/$DMG_NAME"

# Clean up any previous attempts
rm -f "$TEMP_DMG" "$FINAL_DMG"
[ -d "$MOUNT_POINT" ] && umount "$MOUNT_POINT" 2>/dev/null || true
rm -rf "$MOUNT_POINT"

# Create a sparse disk image
hdiutil create -srcfolder "$APP_PATH" -volname "xTC" -fs HFS+ -format UDZO -o "$TEMP_DMG"

# Move to final location
mv "$TEMP_DMG" "$FINAL_DMG"

echo "✅ Created: $FINAL_DMG"
ls -lh "$FINAL_DMG"
