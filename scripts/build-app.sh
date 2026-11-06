#!/bin/bash
# Builds a native arm64 "IR Generator.app" into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="IR Generator"
EXE="IRGenerator"
VERSION="1.0.0"
BUNDLE_ID="local.gm.irgenerator"

swift build -c release --arch arm64 --product "$EXE"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXE"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"

# Backdrop photograph (from gm-guitars.net) and the app's own icon. All other artwork is drawn in code.
cp Assets/atmosphere-bar.jpg "$APP/Contents/Resources/"
ICONSET="build/Icon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>Icon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>IR Generator records the microphone on your audio interface to capture impulse responses.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
lipo -archs "$APP/Contents/MacOS/$EXE"

# --install: copy to /Applications and start it.
if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$NAME.app"
    pkill -f "$NAME.app/Contents/MacOS/$EXE" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed: $DEST"
    open "$DEST"
fi
