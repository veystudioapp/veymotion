#!/bin/bash
# Packages "dist/Vey Motion.app" (built by scripts/bundle.sh) into dist/VeyMotion.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Vey Motion.app"
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
hdiutil create -volname "Vey Motion" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# With a Developer ID (SIGN_IDENTITY, as for bundle.sh) the disk image is signed too, so it can be notarized.
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "Built $DMG"
