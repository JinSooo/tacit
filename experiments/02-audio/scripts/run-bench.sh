#!/bin/sh
# 每个配置启动独立进程；stdout 只到终端，不保存转写文字。
set -eu
cd "$(dirname "$0")/.."
BIN="$PWD/.build/out/Products/Release/bench"
"$BIN" generate
for model in int8 fp32; do
    for threads in 1 2 4; do
        "$BIN" "$model" "$threads"
    done
done
python3 scripts/report.py
