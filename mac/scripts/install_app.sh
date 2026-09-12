#!/bin/zsh
# Installs mac/build/One+Connect.app into /Applications and relaunches it.
# Usage: mac/scripts/install_app.sh [--reset-permissions]
#   --reset-permissions  clears stale Screen Recording / Accessibility grants so macOS asks once, cleanly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/One+Connect.app"
DST="/Applications/One+Connect.app"
BUNDLE_ID="com.pacewisdom.oneplusconnect"
[[ -d "$SRC" ]] || { echo "Build first: mac/scripts/build_app.sh"; exit 1; }

pkill -x OnePlusConnect 2>/dev/null || true
sleep 1
rm -rf "$DST"
ditto "$SRC" "$DST"

if [[ "${1:-}" == "--reset-permissions" ]]; then
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
  tccutil reset Accessibility "$BUNDLE_ID" || true
fi

echo "Installed: $DST"
codesign -dv "$DST" 2>&1 | grep -E "^(Identifier|Signature|Authority)=" || true
open "$DST"
