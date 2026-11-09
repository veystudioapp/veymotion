#!/bin/bash
# Publishes a release that installed apps pick up as an update (through the server's /api/app/latest).
#   1. Bump AppVersion.marketing in Sources/VeyMotionCore/AppVersion.swift and commit.
#   2. bash scripts/release.sh [notes.md]      (needs `gh` logged in with push access to the repo)
# Builds the app, zips it (the updater downloads the zip), builds the DMG (for new users) and creates the
# GitHub release v<version> with both files. Without a notes file, GitHub generates notes from the commits.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*static let marketing = "\(.*\)".*/\1/p' Sources/VeyMotionCore/AppVersion.swift)"
[ -n "$VERSION" ] || { echo "error: cannot read AppVersion.marketing" >&2; exit 1; }
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit your changes first (the release is tagged at HEAD)" >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists; bump AppVersion.marketing first" >&2
  exit 1
fi

bash scripts/bundle.sh
bash scripts/dmg.sh

ZIP="dist/VeyMotion-$VERSION-mac.zip"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact (zip -r does not).
ditto -c -k --sequesterRsrc --keepParent "dist/Vey Motion.app" "$ZIP"
DMG="dist/VeyMotion-$VERSION.dmg"
mv -f dist/VeyMotion.dmg "$DMG"

NOTES=(--generate-notes)
if [ $# -ge 1 ]; then NOTES=(--notes-file "$1"); fi

gh release create "$TAG" "$ZIP" "$DMG" --title "Vey Motion $VERSION" --target "$(git rev-parse HEAD)" "${NOTES[@]}"
echo "Released $TAG"
