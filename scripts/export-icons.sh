#!/bin/sh
# 重用原版 Swift 图标源；--check 在临时目录重建，检查提交的资源是否过期。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tacit-icons.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
case "${1:-}" in
  '') OUT="$ROOT" ;;
  --check) OUT="$WORK/output" ;;
  *) echo "用法: $0 [--check]" >&2; exit 2 ;;
esac
xcrun swiftc "$ROOT/collector/Sources/Collector/Viewer/IconArt.swift" "$ROOT/scripts/export-icons.swift" -o "$WORK/export-icons"
"$WORK/export-icons" "$OUT"
iconutil -c icns "$OUT/assets/icons/generated/macos/AppIcon.iconset" -o "$OUT/assets/icons/generated/macos/AppIcon.icns"
if [ "${1:-}" = --check ]; then
  diff -r "$ROOT/assets/icons/generated" "$OUT/assets/icons/generated"
  diff -r "$ROOT/web/public/icons" "$OUT/web/public/icons"
  cmp "$ROOT/web/public/favicon.ico" "$OUT/web/public/favicon.ico"
  echo "所有图标与绘图源一致。"
fi
