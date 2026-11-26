#!/bin/sh
# 准备应用内更新用的 Sparkle（collector/vendor/Sparkle-<版本>）：框架随应用分发，bin/ 里的 sign_update、generate_keys 发版时用。
# 下载只进入临时目录，校验后再替换。
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.1
sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
vendor="$REPO/collector/vendor"
target="$vendor/Sparkle-$version"
[ -f "$target/.sha256" ] && [ "$(cat "$target/.sha256")" = "$sha" ] && [ -d "$target/Sparkle.framework" ] && exit 0
mkdir -p "$vendor"
staging="$(mktemp -d "$vendor/.download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
curl -fL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$staging/sparkle.tar.xz"
[ "$(shasum -a 256 "$staging/sparkle.tar.xz" | awk '{print $1}')" = "$sha" ] || { echo "Sparkle $version sha256 不符" >&2; exit 1; }
mkdir "$staging/out"
tar -xJf "$staging/sparkle.tar.xz" -C "$staging/out"
[ -d "$staging/out/Sparkle.framework" ] && [ -x "$staging/out/bin/sign_update" ] || { echo "Sparkle $version 压缩包内容不符" >&2; exit 1; }
printf '%s' "$sha" > "$staging/out/.sha256"
rm -rf "$target"
mv "$staging/out" "$target"
