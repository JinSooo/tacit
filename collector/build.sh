#!/bin/sh
# 构建并签名采集端：collector/build/Record Anything.app
set -e
cd "$(dirname "$0")"
./swift.sh build -c release
BIN="$(./swift.sh build -c release --show-bin-path)"
APP="build/Record Anything.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Collector" "$APP/Contents/MacOS/Collector"
VERSION="$(git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.record-anything.collector</string>
  <key>CFBundleName</key><string>Record Anything</string>
  <key>CFBundleExecutable</key><string>Collector</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>录制麦克风中的人声，在本机加密保存并整理对话记录。</string>
  <key>NSAudioCaptureUsageDescription</key><string>录制系统播放的人声，在本机加密保存并整理对话记录。</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>读取已结束的日程，将标题、地点和参会人整理成活动记录。</string>
  <key>NSDesktopFolderUsageDescription</key><string>记录桌面中新出现的文件名和路径，不读取文件内容。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>记录文稿中新出现的文件名和路径，不读取文件内容。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>记录下载完成的文件名、路径和来源，不读取文件内容。</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Frameworks"
LIB="vendor/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/lib"
for lib in "$LIB"/*.dylib; do cp -L "$lib" "$APP/Contents/Frameworks/"; done
# 应用图标由采集端自己画（AppIconArt），这里导出成 icns。
mkdir -p "$APP/Contents/Resources"
rm -rf build/AppIcon.iconset
"$APP/Contents/MacOS/Collector" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset
# 第二个可执行文件由转写任务提供；不存在时采集端照常构建。
if [ -f "$BIN/ra-audio-worker" ]; then cp "$BIN/ra-audio-worker" "$APP/Contents/MacOS/"; fi
cat > build/audio.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
../scripts/dev-cert.sh
KC="$HOME/Library/Keychains/ra-dev.keychain-db"
for lib in "$APP/Contents/Frameworks/"*.dylib; do
  codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime "$lib"
done
if [ -f "$APP/Contents/MacOS/ra-audio-worker" ]; then
  codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements build/audio.entitlements "$APP/Contents/MacOS/ra-audio-worker"
fi
codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements build/audio.entitlements "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP"
