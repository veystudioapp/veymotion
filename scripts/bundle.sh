#!/bin/bash
# Builds a release VeyMotion.app into ./dist (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product VeyMotion
swift build -c release --product vmotion
BIN="$(swift build -c release --show-bin-path)"

APP="dist/VeyMotion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VeyMotion" "$APP/Contents/MacOS/VeyMotion"
# The in-app Claude chat drives the app through this CLI; it must sit next to the app binary.
cp "$BIN/vmotion" "$APP/Contents/MacOS/vmotion"
cp "$BIN/vmotion" dist/vmotion

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VeyMotion</string>
  <key>CFBundleDisplayName</key><string>VeyMotion</string>
  <key>CFBundleIdentifier</key><string>dev.veymotion.app</string>
  <key>CFBundleExecutable</key><string>VeyMotion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>VeyMotion transcribes the speech in your audio and video layers to make captions.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP and dist/vmotion"
