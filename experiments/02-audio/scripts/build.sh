#!/bin/sh
# 所有 Swift/Clang 缓存都留在实验目录，不更改 HOME。
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift build --disable-sandbox -debug-info-format none -c release --scratch-path "$PWD/.build" --cache-path "$PWD/.cache" --config-path "$PWD/.cache/config" --security-path "$PWD/.cache/security"
