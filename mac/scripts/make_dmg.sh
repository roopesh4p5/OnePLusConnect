#!/bin/zsh
# Packages One+Connect.app into a drag-to-Applications disk image for distribution.
# Usage: mac/scripts/make_dmg.sh          (builds the app first if it is not staged)
# Output: dist/One+Connect-<version>.dmg  — older One+Connect dmgs in dist/ are removed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP="$ROOT/build/One+Connect.app"
DIST="$REPO/dist"

[[ -d "$APP" ]] || "$ROOT/scripts/build_app.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/One+Connect-$VERSION.dmg"

mkdir -p "$DIST"
rm -f "$DIST"/One+Connect-*.dmg(N)   # keep exactly one installer in the repo (N: no error when none exist)

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/One+Connect.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "One+Connect" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"
