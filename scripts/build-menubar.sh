#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# build-menubar.sh — produce a redistributable AgentTTSMenubar.app from the
# Swift Package under ui/menubar/.
#
# Pipeline:
#   1. swift build -c release in ui/menubar/
#   2. Assemble a minimal .app bundle (Info.plist with LSUIElement=true)
#   3. Copy the binary into Contents/MacOS/
#
# Output: ui/menubar/build/AgentTTSMenubar.app
#
# Codesigning + notarization are out of scope for v1.10 — Gatekeeper will
# treat the unsigned bundle as "from unidentified developer" until v1.10.1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_ROOT/ui/menubar"
OUT_DIR="$PKG_DIR/build"
APP_NAME="AgentTTSMenubar"
APP="$OUT_DIR/$APP_NAME.app"

if [ ! -d "$PKG_DIR" ]; then
  echo "error: $PKG_DIR not found" >&2
  exit 1
fi

cd "$PKG_DIR"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: built binary missing at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.biliboss.agent-tts.menubar</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>agent-tts</string>
  <key>CFBundleVersion</key><string>1.10.0</string>
  <key>CFBundleShortVersionString</key><string>1.10.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> $APP ready"
echo "    open '$APP'   # or"
echo "    '$APP/Contents/MacOS/$APP_NAME'"
