#!/bin/bash
# Notarizes and staples a Developer ID signed .app or .dmg:
#   bash scripts/notarize.sh "dist/Vey Motion.app"
#
# Credentials, either:
#   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID — the Apple ID + app-specific password (account.apple.com)
#     that CI uses, same secret names as the Vey repo (an App Store Connect API key is not available to the team);
#   NOTARY_PROFILE — notarytool credentials in the login keychain, stored once on a Mac with:
#     xcrun notarytool store-credentials vey-notary --apple-id <apple id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:?usage: notarize.sh <app or dmg>}"
[ -e "$TARGET" ] || { echo "error: $TARGET not found" >&2; exit 1; }
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "error: set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID, or NOTARY_PROFILE" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$TARGET" in
  *.app)
    # notarytool takes a zip, dmg or pkg; ditto keeps the signature intact.
    UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD"
    ;;
  *.dmg) UPLOAD="$TARGET" ;;
  *) echo "error: expected a .app or .dmg" >&2; exit 1 ;;
esac

echo "Notarizing $TARGET (usually a few minutes)…"
RESULT="$WORK/result.json"
# --wait can exit 0 for a rejected submission, so the status is read from the result.
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait --output-format json > "$RESULT" || true
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)"
ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "")"
if [ "$STATUS" != "Accepted" ]; then
  echo "error: notarization of $TARGET ended with status: $STATUS" >&2
  cat "$RESULT" >&2
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

# The stapled ticket lets Gatekeeper accept the file offline.
xcrun stapler staple "$TARGET"
case "$TARGET" in
  *.app) spctl --assess --type execute --verbose "$TARGET" ;;
  *.dmg) spctl --assess --type open --context context:primary-signature --verbose "$TARGET" ;;
esac
echo "Notarized $TARGET"
