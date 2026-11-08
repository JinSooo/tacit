#!/bin/sh
# 在仓库根目录启动；若沙箱禁止监听 127.0.0.1，请在本机终端运行。
set -eu
cd "$(dirname "$0")/../.."
LIB="$PWD/collector/vendor/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/lib"
export DYLD_LIBRARY_PATH="$LIB${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec bun collector/scripts/worker-smoke.ts
