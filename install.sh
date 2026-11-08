#!/bin/sh
# 从源码安装 record-anything：构建网页和采集端，注册 hub 与采集端开机自启（launchd）。
# 重复运行就是升级（git pull && ./install.sh）。卸载：./uninstall.sh
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/Library/Application Support/record-anything"
AGENTS="$HOME/Library/LaunchAgents"
APP_DIR=/Applications; [ -w "$APP_DIR" ] || APP_DIR="$HOME/Applications"
APP="$APP_DIR/Record Anything.app"
DOMAIN="gui/$(id -u)"
step() { printf '\n== %s\n' "$1"; }

BUN="$(command -v bun || true)"
[ -n "$BUN" ] || { echo "需要 bun：https://bun.sh"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "需要 Xcode 命令行工具：xcode-select --install"; exit 1; }
cd "$REPO"

step "安装依赖"
"$BUN" install --frozen-lockfile
step "构建网页"
"$BUN" x vite build --config web/vite.config.ts --logLevel warn
step "构建并签名采集端（固定的自签名证书，升级后系统权限不丢）"
collector/build.sh

step "停止旧进程"
for l in collector hub; do launchctl bootout "$DOMAIN/dev.record-anything.$l" 2>/dev/null || true; done
pkill -f 'Record Anything.app/Contents/MacOS/Collector' 2>/dev/null || true

step "安装采集端到 $APP"
mkdir -p "$APP_DIR"
rm -rf "$APP"
ditto "collector/build/Record Anything.app" "$APP"

step "初始化数据目录和数据库密钥（钥匙串）"
mkdir -p "$DATA/logs"
chmod 700 "$DATA"
"$BUN" hub/src/cli.ts init >/dev/null
# 采集端配置：只更新仓库和 bun 的路径，保留用户改过的其他项。
python3 -I - "$DATA/collector.json" "$REPO" "$BUN" <<'PY'
import json, sys
path, repo, bun = sys.argv[1:4]
try: conf = json.load(open(path))
except Exception: conf = {}
conf.update(repo=repo, bun=bun)
open(path, "w").write(json.dumps(conf, ensure_ascii=False, indent=2) + "\n")
PY

step "注册开机自启"
mkdir -p "$AGENTS"
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > "$AGENTS/dev.record-anything.hub.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.record-anything.hub</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$BUN")</string><string>$(xml "$REPO/hub/src/cli.ts")</string><string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml "$REPO")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$DATA/logs/hub.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$DATA/logs/hub.log")</string>
</dict></plist>
PLIST
cat > "$AGENTS/dev.record-anything.collector.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.record-anything.collector</string>
  <key>ProgramArguments</key><array><string>$(xml "$APP/Contents/MacOS/Collector")</string></array>
  <key>RunAtLoad</key><true/>
  <!-- 从菜单\"退出\"是正常退出，不自动拉起；崩溃才拉起 -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(xml "$(dirname "$BUN")"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardErrorPath</key><string>$(xml "$DATA/logs/collector.log")</string>
</dict></plist>
PLIST
launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.hub.plist"
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS http://127.0.0.1:47823/v1/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:47823/v1/health >/dev/null 2>&1 || { echo "hub 没有启动，看日志：$DATA/logs/hub.log"; exit 1; }
launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.collector.plist"

step "完成"
cat <<MSG
- 菜单栏出现 Record Anything 图标；第一次运行会请求辅助功能权限。
- 打开 History：菜单里点"打开 History"，或运行 bun "$REPO/hub/src/cli.ts" open
- 记录终端命令：在 ~/.zshrc 里加一行
    source "$REPO/plugins/shell/hook.zsh"
- 日志：$DATA/logs/
MSG
