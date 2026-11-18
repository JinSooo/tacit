#!/bin/sh
# 构建采集端前准备 sherpa-onnx 推理库和 C API 头文件（collector/vendor）。下载只进入临时目录，校验后再替换。
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
base="https://github.com/k2-fsa/sherpa-onnx/releases/download"
library=sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib
vendor="$REPO/collector/vendor"
capi_sha=2a169fe29c7e75168cc308b0d5b7f9085efebbb3a7f812d46c3a983d6788759f
ort_sha=3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b
header_sha=5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
mkdir -p "$vendor"
staging="$(mktemp -d "$vendor/.download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
if ! sha_ok "$vendor/$library/lib/libsherpa-onnx-c-api.dylib" "$capi_sha" || ! sha_ok "$vendor/$library/lib/libonnxruntime.dylib" "$ort_sha"; then
  curl -fL --retry 3 "$base/v2.0.1/$library.tar.bz2" -o "$staging/library.tar.bz2"
  tar -xjf "$staging/library.tar.bz2" -C "$staging" "$library"
  sha_ok "$staging/$library/lib/libsherpa-onnx-c-api.dylib" "$capi_sha" && sha_ok "$staging/$library/lib/libonnxruntime.dylib" "$ort_sha" || { echo "sherpa-onnx 库 sha256 不符" >&2; exit 1; }
  rm -rf "$vendor/$library"
  mv "$staging/$library" "$vendor/$library"
fi
# 发布包未带头文件时，取与 dylib 一致的 v2.0.1 C API 头文件。
if ! sha_ok "$vendor/include/sherpa-onnx/c-api/c-api.h" "$header_sha"; then
  mkdir -p "$vendor/include/sherpa-onnx/c-api"
  curl -fL --retry 3 "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h" -o "$staging/c-api.h"
  sha_ok "$staging/c-api.h" "$header_sha" || { echo "sherpa-onnx 头文件 sha256 不符" >&2; exit 1; }
  mv "$staging/c-api.h" "$vendor/include/sherpa-onnx/c-api/c-api.h"
fi
