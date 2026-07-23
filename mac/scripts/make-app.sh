#!/usr/bin/env bash
# Build NetDisplay.app (menu-bar app) from the SwiftPM binary and sign it with
# the stable "NetDisplay Dev" identity so the Screen-Recording grant persists.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ "$CONFIG" = "release" ]; then
  echo "Building NetDisplay (release, universal arm64+x86_64)…"
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/netdisplay-sender"   # fat binary
else
  echo "Building NetDisplay ($CONFIG)…"
  swift build -c "$CONFIG"
  BIN=".build/$CONFIG/netdisplay-sender"
fi

APP_DIR="build/NetDisplay.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
[ -f "$BIN" ] || { echo "Binary not found at $BIN"; exit 1; }
cp "$BIN" "$APP_DIR/Contents/MacOS/netdisplay-sender"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

SIGN_ID="NetDisplay Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --identifier com.hongbo.netdisplay "$APP_DIR"
  echo "Signed with stable identity: $SIGN_ID"
else
  codesign --force --sign - --identifier com.hongbo.netdisplay "$APP_DIR"
  echo "Signed ad-hoc (run scripts/setup-signing.sh once so the Screen-Recording grant persists)"
fi

echo "Built $(pwd)/$APP_DIR"
echo "运行：open \"$(pwd)/$APP_DIR\"    （图标出现在右上角菜单栏）"
