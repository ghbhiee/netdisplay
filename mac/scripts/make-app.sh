#!/usr/bin/env bash
# Build NetDisplay.app (menu-bar app) from the SwiftPM binary and sign it with
# the stable "Hongbo Dev" identity so the Screen-Recording grant persists.
# "Hongbo Dev" is the shared self-signed identity used across this author's local
# apps (see scripts/setup-signing.sh); it replaced the per-project "NetDisplay Dev".
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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

SIGN_ID="Hongbo Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --identifier com.hongbo.netdisplay "$APP_DIR"
  echo "Signed with stable identity: $SIGN_ID"
else
  codesign --force --sign - --identifier com.hongbo.netdisplay "$APP_DIR"
  echo "Signed ad-hoc (run scripts/setup-signing.sh once so the Screen-Recording grant persists)"
fi

echo "Built $(pwd)/$APP_DIR"
echo "运行：open \"$(pwd)/$APP_DIR\"    （图标出现在右上角菜单栏）"

# --- Release zip -------------------------------------------------------------
# MUST use `zip -X` (or `ditto --sequesterRsrc`). A plain `ditto -c -k` writes
# AppleDouble `._*` files INSIDE the bundle on extraction; codesign counts those
# as "files added" and the signature fails with "a sealed resource is missing or
# invalid" — the .app works locally but every downloaded copy is broken. We ship
# the zip only after verifying an actual extracted copy.
ZIP="build/NetDisplay-macOS.zip"
rm -f "$ZIP"
(cd build && zip -q -r -X "NetDisplay-macOS.zip" "NetDisplay.app")

VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT
(cd "$VERIFY_DIR" && unzip -q "$OLDPWD/$ZIP")
if codesign --verify --strict "$VERIFY_DIR/NetDisplay.app" 2>/dev/null; then
  echo "Packaged $(pwd)/$ZIP  （已解压验签通过）"
else
  echo "❌ 打包出的 zip 解压后验签失败——不要发布这个包！" >&2
  codesign --verify --verbose=4 "$VERIFY_DIR/NetDisplay.app" 2>&1 | head -5 >&2
  exit 1
fi
