#!/bin/sh
# 构建发布用的 Mac 安装包 dist/Tacit-<版本>.dmg。只在干净工作区、打了 mac-v<版本> tag 的提交上运行，
# 用本机固定的 “Record Anything Dev” 证书签名：换证书会让已安装用户升级后丢失系统权限，所以缺证书时直接失败，不新建。
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
VERSION="$(bun -e 'console.log(require("./package.json").version)')"
[ -z "$(git status --porcelain)" ] || { echo "工作区有未提交的改动，先提交再构建安装包" >&2; exit 1; }
git tag --points-at HEAD | grep -qx "mac-v$VERSION" || { echo "当前提交没有 mac-v$VERSION 这个 tag" >&2; exit 1; }
grep -q "CFBundleShortVersionString</key><string>$VERSION<" collector/build.sh || { echo "collector/build.sh 的版本号不是 $VERSION" >&2; exit 1; }
grep -q "version: \"$VERSION\"" hub/src/agent-cli/mcp.ts || { echo "MCP serverInfo 的版本号不是 $VERSION" >&2; exit 1; }
security find-certificate -c "Record Anything Dev" "$HOME/Library/Keychains/ra-dev.keychain-db" >/dev/null 2>&1 \
  || { echo "缺少发布签名证书 Record Anything Dev（~/Library/Keychains/ra-dev.keychain-db）" >&2; exit 1; }
# 应用内更新只接受用这把钥匙签过的安装包；丢了它，已装用户就收不到应用内更新。
UPDATE_KEY="$HOME/.config/tacit/sparkle-ed25519.key"
[ -f "$UPDATE_KEY" ] || { echo "缺少应用内更新签名钥匙 $UPDATE_KEY（备份在“Tacit 签名钥匙备份”）" >&2; exit 1; }

bun install --frozen-lockfile
bun x vite build --config web/vite.config.ts --logLevel warn
scripts/fetch-audio-lib.sh
collector/build.sh >/dev/null

OUT="$REPO/dist"; DMG="$OUT/Tacit-$VERSION.dmg"
mkdir -p "$OUT"; rm -f "$DMG" "$DMG.sha256" "$DMG.sparkle"
STAGE="$(mktemp -d)"; MNT="$(mktemp -d)"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$STAGE" "$MNT"' EXIT
# 小窗口里左 Tacit、右“应用程序”、中间箭头，打开就知道该往哪拖（2026-11-25 虚拟机实测：原来是一扇大空白窗口）。
swift scripts/dmg-background.swift "$STAGE" >/dev/null
uvx --from dmgbuild==2.0.0 dmgbuild -s scripts/dmg-settings.py -D app=collector/build/Tacit.app \
  -D background="$STAGE/background.png" "Tacit $VERSION" "$DMG" >/dev/null

# 从安装包里取出的应用必须签名完整、自带的运行时能跑。
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
codesign --verify --deep --strict "$MNT/Tacit.app"
[ -x "$MNT/Tacit.app/Contents/PlugIns/TacitWidget.appex/Contents/MacOS/TacitWidget" ]
"$MNT/Tacit.app/Contents/Helpers/Tacit" --version >/dev/null
[ -f "$MNT/Tacit.app/Contents/Resources/runtime/hub/src/cli.ts" ] && [ -f "$MNT/Tacit.app/Contents/Resources/uninstall.sh" ]
# 应用内更新：框架在，应用里的公钥和本机的签名钥匙是一对。
[ -x "$MNT/Tacit.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$MNT/Tacit.app/Contents/Info.plist")" = "$(bun scripts/sparkle-public-key.ts "$UPDATE_KEY")" ] \
  || { echo "应用里的 SUPublicEDKey 和 $UPDATE_KEY 不是一对" >&2; exit 1; }
hdiutil detach -quiet "$MNT"

(cd "$OUT" && shasum -a 256 "Tacit-$VERSION.dmg" > "Tacit-$VERSION.dmg.sha256")
# Sparkle 签名留给 scripts/publish-mac-update.ts 写进官网的 appcast；先用应用里的公钥验一遍。
collector/vendor/Sparkle-2.10.1/bin/sign_update --ed-key-file "$UPDATE_KEY" "$DMG" > "$DMG.sparkle"
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$DMG.sparkle")"
collector/vendor/Sparkle-2.10.1/bin/sign_update --verify --ed-key-file "$UPDATE_KEY" "$DMG" "$SIG" >/dev/null \
  || { echo "安装包的更新签名校验不通过" >&2; exit 1; }
printf '%s\n%s\n' "$DMG" "$(cat "$DMG.sha256")"
