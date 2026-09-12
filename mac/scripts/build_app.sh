#!/bin/zsh
# Builds One+Connect.app from the Swift package and ad-hoc signs it.
# Usage: mac/scripts/build_app.sh [debug|release]
set -euo pipefail
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/OnePlusConnect"

APP="$ROOT/build/One+Connect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OnePlusConnect"
# App icon (regenerate from logo.png with: swift scripts/make_icons.swift)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>OnePlusConnect</string>
  <key>CFBundleIdentifier</key><string>com.pacewisdom.oneplusconnect</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>One+Connect</string>
  <key>CFBundleDisplayName</key><string>One+Connect</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Developed by Roopesh · Pacewisdom. Local-only, no cloud.</string>
  <key>NSLocalNetworkUsageDescription</key><string>One+Connect looks for your tablet on the local Wi-Fi network when no USB-C cable is connected.</string>
</dict>
</plist>
PLIST

SIGN_ID="${CODESIGN_IDENTITY:-One+Connect Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID (permissions persist across rebuilds)"
else
  codesign --force --deep --sign - "$APP"
  echo "WARNING: ad-hoc signed. macOS will forget Screen Recording/Accessibility on every rebuild."
  echo "         Run once: mac/scripts/make_signing_identity.sh"
fi
echo "Built: $APP"
echo "Install: mac/scripts/install_app.sh [--reset-permissions]"
