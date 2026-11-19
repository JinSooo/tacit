#!/bin/sh
# 卸载 Tacit（源码目录或应用包 Contents/Resources 里都可运行）：停止并移除 hub、提炼与采集端的开机自启、采集端应用和系统权限。数据默认保留。
set -eu
. "$(dirname "$0")/scripts/mac-app.sh"
DATA="$HOME/Library/Application Support/record-anything"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/dev.record-anything.collector" 2>/dev/null || true
for root in /Applications "$HOME/Applications"; do
  app="$root/Tacit.app"
  if tacit_owns_bundle "$app"; then
    tacit_stop_processes "$(tacit_processes "$app/Contents/MacOS/Tacit" "$app/Contents/MacOS/ra-audio-worker")"
  fi
  legacy="$root/Record Anything.app"
  if tacit_owns_bundle "$legacy"; then
    tacit_stop_processes "$(tacit_processes "$legacy/Contents/MacOS/Collector" "$legacy/Contents/MacOS/ra-audio-worker")"
  fi
done
for l in distill hub; do launchctl bootout "$DOMAIN/dev.record-anything.$l" 2>/dev/null || true; done
for l in collector distill hub; do
  rm -f "$AGENTS/dev.record-anything.$l.plist"
  rm -f "$DATA/launch-agents/dev.record-anything.$l.plist"
done
# 重新安装时按全新安装重新准备。
rm -f "$DATA/app-setup.json"
rm -rf "$DATA/widget"
for app in "/Applications/Tacit.app" "$HOME/Applications/Tacit.app" \
           "/Applications/Record Anything.app" "$HOME/Applications/Record Anything.app"; do
  if tacit_owns_bundle "$app"; then
    widget="$app/Contents/PlugIns/TacitWidget.appex"
    if [ -d "$widget" ]; then pluginkit -r "$widget" 2>/dev/null || true; fi
    rm -rf "$app"
  fi
done
tccutil reset All dev.record-anything.collector >/dev/null 2>&1 || true
echo "已移除自启、采集端应用和它的系统权限。"

printf '同时删除全部数据（%s，含加密音频，和钥匙串里的数据库、音频密钥）？删除后不能恢复 [y/N] ' "$DATA"
read -r answer </dev/tty || answer=""
case "$answer" in
  y|Y)
    rm -rf "$DATA"
    security delete-generic-password -s record-anything -a db-key >/dev/null 2>&1 || true
    security delete-generic-password -s record-anything -a audio-key >/dev/null 2>&1 || true
    security delete-generic-password -s record-anything -a audio-key-hex >/dev/null 2>&1 || true
    echo "数据和密钥已删除。" ;;
  *) echo "数据保留在 ${DATA}（含语音模型 models/、加密音频 audio/），密钥保留在钥匙串（record-anything / db-key、audio-key-hex）。两者要一起保留，缺一个数据就打不开。" ;;
esac
echo "如果在 ~/.zshrc 里加过 plugins/shell/hook.zsh，请手动删掉那一行。"
