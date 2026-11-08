#!/bin/sh
# 构建并签名采集端：collector/build/Record Anything.app
set -e
cd "$(dirname "$0")"
../scripts/dev-cert.sh
swift build -c release
APP="build/Record Anything.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Collector "$APP/Contents/MacOS/Collector"
VERSION="$(git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.record-anything.collector</string>
  <key>CFBundleName</key><string>Record Anything</string>
  <key>CFBundleExecutable</key><string>Collector</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
KC="$HOME/Library/Keychains/ra-dev.keychain-db"
codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
