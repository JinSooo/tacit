#!/bin/sh
# SwiftPM 的全部缓存只写 collector/，不触碰系统缓存。
set -eu
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
ACTION="$1"; shift
# SwiftPM 链接时只给 clang 传 --sysroot，clang 不从它读 SDK 版本，把部署目标 14.0 记成"构建所用 SDK"；
# 系统据此让 SwiftUI / AppKit 按 macOS 14 的兼容行为运行（例如工具栏按钮里的图标偏上，2026-11-10）。
# 显式把 -isysroot 传给链接用的 clang。设 SDKROOT 不管用：链接步骤拿不到这个环境变量。
SDK="$(xcrun --sdk macosx --show-sdk-path)"
exec swift "$ACTION" --disable-sandbox -debug-info-format none --scratch-path "$PWD/.build" --cache-path "$PWD/.cache" --config-path "$PWD/.cache/config" --security-path "$PWD/.cache/security" \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK" "$@"
