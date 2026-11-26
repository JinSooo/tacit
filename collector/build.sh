#!/bin/sh
# 构建并签名采集端：collector/build/Tacit.app
set -e
cd "$(dirname "$0")"
./swift.sh build -c release
BIN="$(./swift.sh build -c release --show-bin-path)"
APP="build/Tacit.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Collector" "$APP/Contents/MacOS/Tacit"
VERSION="$(git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)"
# 不声明 CFBundleLocalizations=zh-Hans：声明后中文正文按全宽标点排版，"、""，"后多出半个字的空隙
# （宋体正是为避免这个才选的），应用名也会被系统换成中文、和记录标题对不上。系统菜单和对话框的中文在代码里补。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.record-anything.collector</string>
  <key>CFBundleName</key><string>Tacit</string>
  <key>CFBundleDisplayName</key><string>Tacit</string>
  <key>CFBundleExecutable</key><string>Tacit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7.4</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>dev.record-anything.collector.timeline</string>
    <key>CFBundleURLSchemes</key><array><string>tacit</string></array>
  </dict></array>
  <key>NSBonjourServices</key><array><string>_tacit._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key><string>Tacit lets your phone find this Mac on the local network. 让手机在局域网内找到这台 Mac。</string>
  <key>NSMicrophoneUsageDescription</key><string>Tacit records voices from the microphone to create conversation records and encrypts the audio on this Mac. 录制麦克风中的人声，在本机加密保存并整理对话记录。</string>
  <key>NSAudioCaptureUsageDescription</key><string>Tacit records voices played by the system to create conversation records and encrypts the audio on this Mac. 录制系统播放的人声，在本机加密保存并整理对话记录。</string>
  <key>NSDesktopFolderUsageDescription</key><string>Tacit records only the names and paths of new files on your Desktop. 记录桌面中新出现的文件名和路径，不读取文件内容。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Tacit records only the names and paths of new files in your Documents folder. 记录文稿中新出现的文件名和路径，不读取文件内容。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Tacit records only the names, paths, and sources of completed downloads. 记录下载完成的文件名、路径和来源，不读取文件内容。</string>
</dict></plist>
PLIST
WIDGET="$APP/Contents/PlugIns/TacitWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
cat > "$WIDGET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.record-anything.collector.widget</string>
  <key>CFBundleName</key><string>TacitWidget</string>
  <key>CFBundleDisplayName</key><string>Tacit</string>
  <key>CFBundleExecutable</key><string>TacitWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST
# ExtensionFoundation needs the Foundation entry point. Keep the Swift @main it dispatches to.
xcrun --sdk macosx swiftc -target arm64-apple-macosx14.0 -O -application-extension -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -u -Xlinker _main \
  Sources/CollectorCore/WidgetSnapshot.swift Sources/CollectorCore/AppLanguage.swift Sources/CollectorCore/L10n.swift \
  Sources/Collector/Viewer/Palette.swift Widget/DayWidgetView.swift Widget/TacitWidget.swift \
  -o "$WIDGET/Contents/MacOS/TacitWidget"
mkdir -p "$APP/Contents/Frameworks"
LIB="vendor/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/lib"
for lib in "$LIB"/*.dylib; do cp -L "$lib" "$APP/Contents/Frameworks/"; done
# 应用图标由采集端自己画（AppIconArt），这里导出成 icns。
mkdir -p "$APP/Contents/Resources"
# 查看窗口和菜单栏的图标字体（Phosphor，MIT），启动时注册到进程。
cp -R Resources/Phosphor "$APP/Contents/Resources/Phosphor"
# 侧栏选中底色和侧栏图标跟随应用的 AccentColor，SwiftUI 的 .tint 管不到；使用暖灰选中态；内容区的强调色单独由 Palette 控制。
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist build/assets-info.plist >/dev/null
rm -rf build/AppIcon.iconset
"$APP/Contents/MacOS/Tacit" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset
# 第二个可执行文件由转写任务提供；不存在时采集端照常构建。
if [ -f "$BIN/ra-audio-worker" ]; then cp "$BIN/ra-audio-worker" "$APP/Contents/MacOS/"; fi
# 后台服务的运行时随应用分发，用户不用自己装 Bun。来源必须是 Bun 官方签名的版本；拷进应用后用本应用的证书重签，
# 原样沿用它的权限（JIT 等），文件名叫 Tacit、放在 Helpers 里：系统“后台运行”提示写的是这个程序的签名者或文件名，
# 保留官方签名时显示 Bun 作者的名字，重签后显示 “bun”（2026-11-24 虚拟机联调发现）。
BUN_SRC="$(/usr/bin/readlink -f "$(command -v bun)")"
codesign -dv "$BUN_SRC" 2>&1 | grep -q '^TeamIdentifier=7FRXF46ZSN$' || { echo "$BUN_SRC 不是 Bun 官方签名的版本" >&2; exit 1; }
lipo -archs "$BUN_SRC" | grep -qw arm64 || { echo "$BUN_SRC 不含 arm64" >&2; exit 1; }
RUNTIME_BIN="$APP/Contents/Helpers/Tacit"
mkdir -p "$APP/Contents/Helpers"
cp "$BUN_SRC" "$RUNTIME_BIN"
codesign -d --entitlements - --xml "$RUNTIME_BIN" > build/bun.entitlements 2>/dev/null
grep -q "com.apple.security.cs.allow-jit" build/bun.entitlements || { echo "没有读到 Bun 的 JIT 权限" >&2; exit 1; }
# 卸载脚本随应用分发，安装包用户也能完整卸载。
cp ../uninstall.sh "$APP/Contents/Resources/uninstall.sh"
mkdir -p "$APP/Contents/Resources/scripts"
cp ../scripts/mac-app.sh "$APP/Contents/Resources/scripts/mac-app.sh"
# 自签名证书没有团队编号。开了加固运行时后，SIP 开着的 Mac 会按“团队不同”拒绝加载自带的语音库，
# 应用一打开就崩（2026-11-24 在 SIP 开启的虚拟机里发现，开发机关了 SIP 看不到），所以关掉库校验。
cat > build/audio.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
cp build/audio.entitlements build/app.entitlements
# 回归检查：构建 SDK 被记成部署目标时，系统让 SwiftUI 按 macOS 14 的兼容行为运行（工具栏图标偏上），见 swift.sh。
for bin in "$APP/Contents/MacOS/Tacit" "$APP/Contents/MacOS/ra-audio-worker"; do
  [ -f "$bin" ] || continue
  sdk="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')"
  [ "$sdk" != "14.0" ] || { echo "$bin 的构建 SDK 被记成 14.0（应为 $(xcrun --sdk macosx --show-sdk-version)）" >&2; exit 1; }
done
# 与采集端一同签名的后台运行快照。先构建网页，再执行本脚本。
bun ../scripts/stage-runtime.ts .. "$APP/Contents/Resources/runtime"
../scripts/dev-cert.sh
KC="$HOME/Library/Keychains/ra-dev.keychain-db"
for lib in "$APP/Contents/Frameworks/"*.dylib; do
  codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime "$lib"
done
codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements build/bun.entitlements "$RUNTIME_BIN"
if [ -f "$APP/Contents/MacOS/ra-audio-worker" ]; then
  codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements build/audio.entitlements "$APP/Contents/MacOS/ra-audio-worker"
fi
codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements Widget/Widget.entitlements "$WIDGET"
codesign --force --keychain "$KC" -s "Record Anything Dev" -o runtime --entitlements build/app.entitlements "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP"
# 回归检查：加载自带动态库的两个程序必须带上关闭库校验的授权，见上方 audio.entitlements 的说明。
for bin in "$APP" "$APP/Contents/MacOS/ra-audio-worker"; do
  [ -e "$bin" ] || continue
  codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q "com.apple.security.cs.disable-library-validation" \
    || { echo "$bin 缺少 disable-library-validation 授权，SIP 开着的 Mac 上会打不开" >&2; exit 1; }
done
# 回归检查：自带的 Bun 由本应用的证书签名，且重签后仍能运行（JIT 权限生效）。
codesign -dvv "$RUNTIME_BIN" 2>&1 | grep -q '^Authority=Record Anything Dev$' \
  || { echo "自带的运行时没有用本应用的证书重签，系统后台提示会显示 Bun 作者的名字" >&2; exit 1; }
[ "$("$RUNTIME_BIN" -e 'let s = 0; for (let i = 0; i < 1e6; i++) s += i; console.log(s)')" = "499999500000" ] \
  || { echo "重签后的运行时无法运行" >&2; exit 1; }
# Bundled localizations change AppKit punctuation spacing and other applications' display names.
LOCALIZATIONS="$(find "$APP" -iname '*.lproj' -print)"
[ -z "$LOCALIZATIONS" ] || { printf 'Unexpected bundle localizations:\n%s\n' "$LOCALIZATIONS" >&2; exit 1; }
for plist in "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist"; do
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations' "$plist" >/dev/null 2>&1 ||
     [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$plist" 2>/dev/null)" = "zh-Hans" ]; then
    echo "$plist declares a forbidden bundle localization" >&2
    exit 1
  fi
done
