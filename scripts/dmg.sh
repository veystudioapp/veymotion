#!/bin/bash
# Packages dist/VeyMotion.app (built by scripts/bundle.sh) into dist/VeyMotion.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/VeyMotion.app"
if [ ! -d "$APP" ]; then
  echo "error: $APP not found, run scripts/bundle.sh first (or 'make bundle')" >&2
  exit 1
fi

DMG="dist/VeyMotion.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "VeyMotion" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Built $DMG"
