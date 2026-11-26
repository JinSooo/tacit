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
# The phone sends the same prompts and schemas as the hub. Its parser reads limits from those schemas.
python3 - "$base/../hub/src/distill/prompts" "$base/app/src/main/java/top/jinso/tacit/summary/PhoneSummaries.kt" <<'PYTHON'
import json
import re
import sys
from pathlib import Path

phone = Path(sys.argv[2]).read_text(encoding="utf-8")
for language, suffix in (("zh", ""), ("en", "_EN")):
    hub = (Path(sys.argv[1]) / f"{language}.ts").read_text(encoding="utf-8")
    system = f"CONVERSATION_SYSTEM{suffix}"
    hub_prompt = re.search(rf"export const {system} = `(.*?)`;", hub, re.S)
    phone_prompt = re.search(rf'const val SYSTEM{suffix} = """(.*?)"""', phone, re.S)
    if not hub_prompt or not phone_prompt or hub_prompt[1] != phone_prompt[1]:
        sys.exit(f"Android {language} conversation prompt differs from {system}")

    name = f"CONVERSATION_SCHEMA_{language.upper()}"
    schema = re.search(rf"export const {name} = (\{{.*?\n\}}) as const;", hub, re.S)
    phone_schema = re.search(rf'const val SCHEMA{suffix} = """(.*?)"""', phone, re.S)
    if not schema or not phone_schema:
        sys.exit(f"Missing Android or Hub {language} conversation schema")
    # The Hub constants use JSON values with unquoted keys and trailing commas.
    hub_json = re.sub(r'\b(\w+):', r'"\1":', schema[1])
    hub_json = re.sub(r',\s*([}\]])', r'\1', hub_json)
    if json.loads(hub_json) != json.loads(phone_schema[1]):
        sys.exit(f"Android {language} conversation schema differs from {name}")
    print(f"Android {language} conversation prompt and schema match the Hub")
PYTHON
"$base/gradlew" -p "$base" --offline testDebugUnitTest assembleDebug lintDebug assembleDebugAndroidTest
