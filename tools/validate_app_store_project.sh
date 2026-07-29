#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT_DIR/xTC.xcodeproj/project.pbxproj"
PLIST="$ROOT_DIR/xTC/Info.plist"
ENTITLEMENTS="$ROOT_DIR/xTC/xTC.entitlements"

grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.luoxiliu.xtc;' "$PBXPROJ"
grep -q 'ARCHS = arm64;' "$PBXPROJ"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 13.0;' "$PBXPROJ"
/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$PLIST" | grep -q false
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" | grep -q true
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS" | grep -q true
