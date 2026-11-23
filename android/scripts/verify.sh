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
# The phone writes conversation summaries with the Mac's prompt; a copy that drifts writes differently shaped summaries.
python3 - "$base/../hub/src/distill/prompts.ts" "$base/app/src/main/java/top/jinso/tacit/summary/PhoneSummaries.kt" <<'PY'
import re, sys
hub = re.search(r'export const CONVERSATION_SYSTEM = `(.*?)`;', open(sys.argv[1], encoding="utf-8").read(), re.S)
phone = re.search(r'const val SYSTEM = """(.*?)"""', open(sys.argv[2], encoding="utf-8").read(), re.S)
if not hub or not phone or hub.group(1) != phone.group(1):
    sys.exit("手机的对话总结提示词与 hub/src/distill/prompts.ts 的 CONVERSATION_SYSTEM 不一致")
PY
"$base/gradlew" -p "$base" --offline testDebugUnitTest assembleDebug lintDebug assembleDebugAndroidTest
