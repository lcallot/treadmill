#!/bin/bash
# Build Treadmill.app (menu-bar app) into ./build.
#   scripts/build-app.sh            build + ad-hoc sign
#   scripts/build-app.sh --install  also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Treadmill.app"
swift build -c release --product TreadmillApp
BIN="$(swift build -c release --show-bin-path)/TreadmillApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Treadmill"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Treadmill</string>
    <key>CFBundleIdentifier</key><string>local.treadmill</string>
    <key>CFBundleName</key><string>Treadmill</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Treadmill connects to your WalkingPad over Bluetooth to control it.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Treadmill.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Treadmill.app"
fi
