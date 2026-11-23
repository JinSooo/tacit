#!/bin/sh
# macOS + Xcode。用法：./scripts/export-widget-previews.sh [输出目录]
# 默认更新 assets/readme/widget-{light,dark}.png。传入目录时也输出单独的中号和大号预览。
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM

xcrun --sdk macosx swiftc -target arm64-apple-macosx14.0 -parse-as-library \
  "$root/collector/Sources/CollectorCore/WidgetSnapshot.swift" \
  "$root/collector/Sources/Collector/Viewer/Palette.swift" \
  "$root/collector/Widget/DayWidgetView.swift" "$root/scripts/export-widget-previews.swift" \
  -o "$work/export-widget-previews"

if [ "$#" -eq 0 ]; then
  TZ=UTC "$work/export-widget-previews" "$root/assets/readme"
else
  TZ=UTC "$work/export-widget-previews" "$1" --individual
fi
