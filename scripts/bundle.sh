#!/bin/bash
# Builds a release "Vey Motion.app" into ./dist.
#
#   ARCHS="arm64 x86_64"   architectures to build (default: this Mac's); several are merged with lipo
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                          signs with hardened runtime + timestamp, as notarization needs (default: ad-hoc,
#                          which only runs on this Mac; see scripts/notarize.sh and scripts/release.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

# The version lives in Swift (AppVersion.marketing); the build number is the commit count.
VERSION="$(sed -n 's/.*static let marketing = "\(.*\)".*/\1/p' Sources/VeyMotionCore/AppVersion.swift)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[ -n "$VERSION" ] || { echo "error: cannot read AppVersion.marketing" >&2; exit 1; }

ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# One build per architecture (a multi-arch `swift build --arch a --arch b` needs Xcode's build system).
BINS=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx14.0"
  swift build -c release --triple "$triple" --product VeyMotion
  swift build -c release --triple "$triple" --product vmotion
  BINS+=("$(swift build -c release --triple "$triple" --show-bin-path)")
done

APP="dist/Vey Motion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for product in VeyMotion vmotion; do
  inputs=()
  for bin in "${BINS[@]}"; do inputs+=("$bin/$product"); done
  # The in-app Claude chat drives the app through vmotion; it must sit next to the app binary.
  lipo -create "${inputs[@]}" -output "$APP/Contents/MacOS/$product"
done
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/VeyMotion")"

# App icon: resources/icon.png is a 1024x1024 render of resources/logo.svg.
ICONSET="dist/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" resources/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" resources/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vey Motion</string>
  <key>CFBundleDisplayName</key><string>Vey Motion</string>
  <key>CFBundleIdentifier</key><string>dev.veymotion.app</string>
  <key>CFBundleExecutable</key><string>VeyMotion</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Vey Motion transcribes the speech in your audio and video layers to make captions.</string>
</dict>
</plist>
PLIST

# The server the app talks to: $BASE_API_URL, else the repo's .env. Only this one line goes into the app
# (Contents/Resources/.env), so nothing else from .env ships; a .env in Application Support/VeyMotion overrides it.
API_URL="${BASE_API_URL:-}"
if [ -z "$API_URL" ] && [ -f .env ]; then
  API_URL="$(sed -n 's/^BASE_API_URL=//p' .env | tail -1 | tr -d "\"' \r")"
fi
if [ -n "$API_URL" ]; then
  echo "BASE_API_URL=$API_URL" > "$APP/Contents/Resources/.env"
  echo "Server: $API_URL"
  case "$API_URL" in
    *localhost*|*127.0.0.1*) echo "warning: this build talks to a local server ($API_URL); set BASE_API_URL for a release" >&2 ;;
  esac
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP/Contents/MacOS/vmotion"
  codesign --force --sign - "$APP"
  echo "warning: ad-hoc signed; other Macs refuse to open it (set SIGN_IDENTITY for a release)" >&2
else
  # Inside out: the nested CLI first, then the bundle (whose seal covers it). No --deep: it is deprecated for signing.
  SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
  "${SIGN[@]}" --identifier dev.veymotion.vmotion "$APP/Contents/MacOS/vmotion"
  "${SIGN[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
cp "$APP/Contents/MacOS/vmotion" dist/vmotion
AUTHORITY="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Built $APP $VERSION ($BUILD) and dist/vmotion, signed by: ${AUTHORITY:-ad-hoc}"
