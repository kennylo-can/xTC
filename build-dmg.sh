#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="xTC"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
GUIDE_SOURCE="$ROOT_DIR/release/Gatekeeper Guide.md"

"$ROOT_DIR/build-app.sh"

rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE"

cp -R "$APP_BUNDLE" "$DMG_STAGE/"
cp "$GUIDE_SOURCE" "$DMG_STAGE/Gatekeeper Guide.md"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

echo "Built: $DMG_PATH"
