#!/bin/sh
# SwiftPM 的全部缓存只写 collector/，不触碰系统缓存。
set -eu
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
ACTION="$1"; shift
exec swift "$ACTION" --disable-sandbox -debug-info-format none --scratch-path "$PWD/.build" --cache-path "$PWD/.cache" --config-path "$PWD/.cache/config" --security-path "$PWD/.cache/security" "$@"
