#!/bin/sh
# 构建发布用的 Android 安装包 dist/Tacit-<版本>.apk。只在干净工作区、打了 v<版本> tag 的提交上运行，
# 用固定的正式签名钥匙（~/.config/tacit/android-release.p12，密码在登录钥匙串）签名：换钥匙会让已安装的手机
# 无法覆盖升级、只能卸载重装并丢掉手机上的数据，所以钥匙缺失或指纹不对时直接失败，不新建。
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
CERT_SHA256=419917729837ebd0e4a24633cd7ed21b75a861f55a1718b95b5d897a8efa1b4f
VERSION="$(bun -e 'console.log(require("./package.json").version)')"
[ -z "$(git status --porcelain)" ] || { echo "工作区有未提交的改动，先提交再构建安装包" >&2; exit 1; }
[ "$(git describe --tags --exact-match 2>/dev/null || true)" = "v$VERSION" ] || { echo "当前提交没有 v$VERSION 这个 tag" >&2; exit 1; }
grep -q "versionName = \"$VERSION\"" android/app/build.gradle.kts || { echo "android/app/build.gradle.kts 的 versionName 不是 $VERSION" >&2; exit 1; }
[ -f "$HOME/.config/tacit/android-release.p12" ] || { echo "缺少 Android 正式签名钥匙 ~/.config/tacit/android-release.p12" >&2; exit 1; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
APKSIGNER="$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -1)"
android/gradlew -p android --offline -q assembleRelease

APK=android/app/build/outputs/apk/release/app-release.apk
CERTS="$("$APKSIGNER" verify --print-certs "$APK")"
[ "$(printf '%s\n' "$CERTS" | grep -c 'certificate SHA-256 digest')" = 1 ] \
  && printf '%s\n' "$CERTS" | grep -q "certificate SHA-256 digest: $CERT_SHA256" \
  || { echo "$APK 不是用 Tacit 正式钥匙签的" >&2; printf '%s\n' "$CERTS" >&2; exit 1; }

OUT="$REPO/dist"; DEST="$OUT/Tacit-$VERSION.apk"
mkdir -p "$OUT"; rm -f "$DEST" "$DEST.sha256"
cp "$APK" "$DEST"
(cd "$OUT" && shasum -a 256 "Tacit-$VERSION.apk" > "Tacit-$VERSION.apk.sha256")
printf '%s\n%s\n' "$DEST" "$(cat "$DEST.sha256")"
