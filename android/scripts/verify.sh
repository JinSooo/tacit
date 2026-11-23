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
# The app's icons are copies of the shared export; a stale copy made the HyperOS ring touch the tile edge (2026-11-23).
generated="$base/../assets/icons/generated/android/res"
(cd "$generated" && find . -type f) | while read -r file; do
    cmp -s "$generated/$file" "$base/app/src/main/res/$file" || { echo "Android 图标与 assets/icons/generated 不一致: $file（运行 scripts/export-icons.sh 后复制）" >&2; exit 1; }
done
"$base/gradlew" -p "$base" --offline testDebugUnitTest assembleDebug lintDebug assembleDebugAndroidTest
