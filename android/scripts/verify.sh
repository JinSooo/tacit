#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
libs="$base/app/libs"
export PYTHONDONTWRITEBYTECODE=1
if ! test -s "$libs/sherpa-onnx-2.0.1.aar" || ! test -s "$libs/sherpa-onnx-2.0.1-qnn-arm64.aar"; then
    "$base/scripts/prepare-speech.sh"
fi
python3 "$base/scripts/test-speech-abi.py"
python3 "$base/scripts/test-verify-device.py"
"$base/gradlew" -p "$base" --offline testDebugUnitTest assembleDebug lintDebug assembleDebugAndroidTest
