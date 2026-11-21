#!/bin/bash
# Publishes a release that installed apps pick up as an update (through the server's /api/app/latest).
# Normally run by .github/workflows/release.yml on a pushed tag:
#   1. Bump AppVersion.marketing in Sources/VeyMotionCore/AppVersion.swift and commit.
#   2. git tag v<version> && git push --tags
# By hand on a Mac with the Developer ID in the keychain (needs `gh` logged in with push access):
#   SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE=vey-notary bash scripts/release.sh [notes.md]
# (codesign accepts the start of the certificate's name; notarization credentials: see scripts/notarize.sh).
#
# Builds a universal app signed with the Developer ID, notarizes and staples it, zips it (the updater downloads
# the zip), builds, signs and notarizes the DMG (for new users) and creates the GitHub release v<version> with both
# files. Without a notes file, GitHub generates notes from the commits. PUBLISH=0 builds everything into dist/
# without creating the release.
#
# Installed Developer ID builds only take updates signed by the same team (Updater.stage). ALLOW_ADHOC=1 builds an
# ad-hoc release anyway: Gatekeeper blocks it on download and signed installs refuse it as an update.
set -euo pipefail
cd "$(dirname "$0")/.."

export ARCHS="${ARCHS:-arm64 x86_64}"
PUBLISH="${PUBLISH:-1}"
SIGNED=1
if [ -z "${SIGN_IDENTITY:-}" ] || [ "$SIGN_IDENTITY" = "-" ]; then
  if [ "${ALLOW_ADHOC:-}" != 1 ]; then
    echo "error: set SIGN_IDENTITY to your Developer ID Application certificate" >&2
    echo "       (security find-identity -v -p codesigning lists them), or ALLOW_ADHOC=1" >&2
    exit 1
  fi
  SIGNED=0
  SIGN_IDENTITY=-
  echo "warning: building an ad-hoc signed release" >&2
elif [ -z "${NOTARY_PROFILE:-}" ] &&
     { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; }; then
  echo "error: no notarization credentials (see scripts/notarize.sh); signed but not notarized is refused by" >&2
  echo "       Gatekeeper all the same" >&2
  exit 1
fi
export SIGN_IDENTITY

VERSION="$(sed -n 's/.*static let marketing = "\(.*\)".*/\1/p' Sources/VeyMotionCore/AppVersion.swift)"
[ -n "$VERSION" ] || { echo "error: cannot read AppVersion.marketing" >&2; exit 1; }
TAG="v$VERSION"

# On CI the tag comes first: one that disagrees with the code would publish v0.2.0 holding a 0.1.0 app.
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "$GITHUB_REF_NAME" != "$TAG" ]; then
  echo "error: tag $GITHUB_REF_NAME does not match AppVersion.marketing $VERSION" >&2
  exit 1
fi
if [ "$PUBLISH" = 1 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "error: commit your changes first (the release is tagged at HEAD)" >&2
    exit 1
  fi
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: release $TAG already exists; bump AppVersion.marketing first" >&2
    exit 1
  fi
fi

bash scripts/bundle.sh
# Staple the app before it goes into the zip and the DMG, so both carry the ticket.
if [ "$SIGNED" = 1 ]; then bash scripts/notarize.sh "dist/Vey Motion.app"; fi
bash scripts/dmg.sh
if [ "$SIGNED" = 1 ]; then bash scripts/notarize.sh dist/VeyMotion.dmg; fi

ZIP="dist/VeyMotion-$VERSION-mac.zip"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact (zip -r does not).
ditto -c -k --sequesterRsrc --keepParent "dist/Vey Motion.app" "$ZIP"
DMG="dist/VeyMotion-$VERSION.dmg"
mv -f dist/VeyMotion.dmg "$DMG"

if [ "$PUBLISH" != 1 ]; then
  echo "Built $ZIP and $DMG (not published)"
  exit 0
fi

NOTES=(--generate-notes)
if [ $# -ge 1 ]; then NOTES=(--notes-file "$1"); fi

gh release create "$TAG" "$ZIP" "$DMG" --title "Vey Motion $VERSION" --target "$(git rev-parse HEAD)" "${NOTES[@]}"
echo "Released $TAG"
