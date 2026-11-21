#!/bin/bash
# Builds the app next to the project: a double-clickable app with the CLI inside.
# Usage: Scripts/make-app.sh   (needs Xcode or the Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep in sync with Sources/GamePortKit/Brand.swift.
DISPLAY_NAME="GamePort"
BUNDLE_NAME="GamePort"
EXECUTABLE_NAME="GamePortApp"
BUNDLE_ID="app.gameport.GamePort"

swift build -c release --product GamePortApp
swift build -c release --product gameport
BIN="$(swift build -c release --show-bin-path)"

APP="build/$BUNDLE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep the GUI executable name distinct from the CLI (`gameport`) for case-insensitive APFS.
cp "$BIN/GamePortApp" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$BIN/gameport" "$APP/Contents/MacOS/gameport"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>For in-game voice chat.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac. Distribution needs a Developer ID and notarization.
codesign --force --sign - "$APP/Contents/MacOS/gameport"
codesign --force --sign - "$APP"
echo "Ready: $(pwd)/$APP"
