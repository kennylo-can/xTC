#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="xTC"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_PATH="$MACOS_DIR/$APP_NAME"
SDK_PATH="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="/private/tmp/xtc-modulecache"
ICON_REFERENCE="$ROOT_DIR/assets/AppIconReference.png"
ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"
LTC_C_DIR="$ROOT_DIR/vendor/libltc"
LTC_BRIDGE_HEADER="$ROOT_DIR/macapp/LTCBridge.h"

# Detect host architecture and build accordingly
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "arm64" ]; then
  TARGET="arm64-apple-macos13.0"
else
  TARGET="x86_64-apple-macos13.0"
fi
LTC_DECODER_OBJ="$BUILD_DIR/decoder.o"

mkdir -p "$MODULE_CACHE" "$MACOS_DIR" "$RESOURCES_DIR"

if [ ! -f "$ICON_REFERENCE" ]; then
  echo "Missing icon reference: $ICON_REFERENCE" >&2
  exit 1
fi

echo "→ Generating app icon..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift "$ROOT_DIR/tools/generate_app_icon.swift" "$ICON_REFERENCE" "$ICNS_PATH"

echo "→ Compiling LTC C decoder ($TARGET)..."
clang -std=c99 -O2 -target "$TARGET" -isysroot "$SDK_PATH" \
  -I"$LTC_C_DIR" -c "$LTC_C_DIR/decoder.c" -o "$LTC_DECODER_OBJ"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>xTC</string>
  <key>CFBundleDisplayName</key>
  <string>xTC</string>
  <key>CFBundleExecutable</key>
  <string>xTC</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.luoxiliu.xtc</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.5</string>
  <key>CFBundleVersion</key>
  <string>5</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>xTC uses audio input to decode LTC timecode.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

echo "→ Compiling Swift sources ($TARGET)..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc -parse-as-library \
  -import-objc-header "$LTC_BRIDGE_HEADER" \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  "$ROOT_DIR/macapp/xTCApp.swift" \
  "$ROOT_DIR/macapp/Localization.swift" \
  "$ROOT_DIR/macapp/AppIconSupport.swift" \
  "$ROOT_DIR/macapp/WindowSizer.swift" \
  "$ROOT_DIR/macapp/ContentView.swift" \
  "$ROOT_DIR/macapp/AudioLTCManager.swift" \
  "$ROOT_DIR/macapp/AudioLTCOutputManager.swift" \
  "$ROOT_DIR/macapp/TimecodeMath.swift" \
  "$ROOT_DIR/macapp/MIDIManager.swift" \
  "$ROOT_DIR/macapp/MIDIOutputManager.swift" \
  "$LTC_DECODER_OBJ" \
  -o "$BIN_PATH" \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreMIDI \
  -framework CoreAudio \
  -framework AVFAudio

chmod +x "$BIN_PATH"
echo ""
echo "✅ Built: $APP_BUNDLE"
