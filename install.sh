#!/bin/sh
# 从源码安装 Tacit：构建网页和采集端，再走与安装包首次打开相同的准备流程（hub/src/setup.ts）。
# 重复运行就是升级（git pull && ./install.sh）。卸载：./uninstall.sh
set -eu
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  [zZ][hH]*) tacit_lang=zh ;;
  *) tacit_lang=en ;;
esac
local_text() {
  if [ "$tacit_lang" = zh ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
local_line() { local_text "$1" "$2"; printf '\n'; }
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/scripts/mac-app.sh"
DATA="${RA_DATA_DIR-$HOME/Library/Application Support/record-anything}"
APP_DIR="$(tacit_install_dir /Applications "$HOME/Applications")"
APP="$APP_DIR/Tacit.app"
LEGACY="$APP_DIR/Record Anything.app"
RUNTIME="$APP/Contents/Resources/runtime"
DOMAIN="gui/$(id -u)"
step() { printf '\n== %s\n' "$1"; }

job_plist() {
  printf 'dev.record-anything.%s.plist\n' "$1"
}

snapshot_services() {
  mkdir "$staging/LaunchAgents" "$staging/launch-agents"
  : > "$staging/loaded-jobs"
  for job in hub distill collector; do
    file="$(job_plist "$job")"
    if [ -f "$HOME/Library/LaunchAgents/$file" ]; then
      cp -p "$HOME/Library/LaunchAgents/$file" "$staging/LaunchAgents/$file"
    fi
    if [ -f "$DATA/launch-agents/$file" ]; then
      cp -p "$DATA/launch-agents/$file" "$staging/launch-agents/$file"
    fi
    if launchctl print "$DOMAIN/dev.record-anything.$job" >/dev/null 2>&1; then
      printf '%s\n' "$job" >> "$staging/loaded-jobs"
    fi
  done
  for file in collector.json app-setup.json; do
    if [ -f "$DATA/$file" ]; then cp -p "$DATA/$file" "$staging/$file"; fi
  done
}

restore_file() {
  if [ -f "$1" ]; then cp -p "$1" "$2"; else rm -f "$2"; fi
}

restore_install() {
  failed=0
  rollback_remote=false
  # 与 hub/src/hub-binding.ts 同一套判定：文件存在（含悬空链接）就必须合法；损坏时按远端处理，不拉起本机后台和整理。
  # 不在 shell 里预判文件是否存在（目录无权限时 -e 会误判为不存在），一律交给读取器。
  if ! rollback_remote="$("$BUN" --no-env-file -e '
    const { readHubBinding } = await import(process.argv[1]);
    console.log(readHubBinding(process.argv[2]).remote !== null);
  ' "$REPO/hub/src/hub-binding.ts" "$DATA" 2>/dev/null)"; then
    printf '%s\n' '{"code":"install_binding_invalid"}' >&2
    rollback_remote=true
  fi
  if [ "$setup_started" = 1 ]; then
    for job in collector distill hub; do
      launchctl bootout "$DOMAIN/dev.record-anything.$job" >/dev/null 2>&1 || true
    done
    for job in collector distill hub; do
      target="$DOMAIN/dev.record-anything.$job"
      for retry in 1 2 3 4 5; do
        launchctl print "$target" >/dev/null 2>&1 || break
        sleep 1
      done
      if launchctl print "$target" >/dev/null 2>&1; then
        printf "$(local_text '没能退出新版后台任务 %s。\n' 'Could not stop the new background job %s.\n')" "$job" >&2
        failed=1
      fi
    done
  fi
  if [ ! -d "$staging/Tacit.app" ]; then rm -rf "$APP" || return 1; fi
  if [ -d "$previous_app" ]; then mv "$previous_app" "$APP" || return 1; fi
  if [ -d "$staging/previous.bundle" ]; then mv "$staging/previous.bundle" "$LEGACY" || failed=1; fi
  if [ "$setup_started" = 1 ]; then
    for job in hub distill collector; do
      if [ "$rollback_remote" = true ] && [ "$job" != collector ]; then continue; fi
      file="$(job_plist "$job")"
      restore_file "$staging/LaunchAgents/$file" "$HOME/Library/LaunchAgents/$file" || failed=1
      restore_file "$staging/launch-agents/$file" "$DATA/launch-agents/$file" || failed=1
    done
    for file in collector.json app-setup.json; do
      restore_file "$staging/$file" "$DATA/$file" || failed=1
    done
  fi
  while IFS= read -r job; do
    if [ "$rollback_remote" = true ] && [ "$job" != collector ]; then continue; fi
    target="$DOMAIN/dev.record-anything.$job"
    file="$(job_plist "$job")"
    plist="$HOME/Library/LaunchAgents/$file"
    if [ -f "$DATA/launch-agents/$file" ]; then plist="$DATA/launch-agents/$file"; fi
    if launchctl print "$target" >/dev/null 2>&1; then continue; fi
    loaded=0
    for retry in 1 2 3 4 5; do
      if launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1; then loaded=1; break; fi
      sleep 1
    done
    if [ "$loaded" = 0 ]; then
      printf "$(local_text '没能重新加载旧后台任务 %s。\n' 'Could not reload the previous background job %s.\n')" "$job" >&2
      failed=1
    fi
  done < "$staging/loaded-jobs"
  return "$failed"
}

finish_install() {
  status="$1"
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$status" -ne 0 ]; then
    printf "$(local_text 'Tacit 源码安装失败（退出码 %s）。\n' 'Tacit source installation failed (exit code %s).\n')" "$status" >&2
    if [ "$switching" = 1 ]; then
      if restore_install; then
        printf "$(local_text '已回滚应用和后台启动项，并重新加载原先运行的任务。\n' 'Restored the previous application and restarted its background jobs.\n')" >&2
      else
        printf "$(local_text '自动回滚未完整完成。安装备份保留在 %s（应用备份如有，在 %s）。\n' 'Rollback did not finish. The installation backup is at %s. If present, the app backup is at %s.\n')" "$staging" "$previous_app" >&2
        exit "$status"
      fi
    fi
  fi
  rm -rf "$staging"
  exit "$status"
}

save_rename_backup() (
  set -eu
  umask 077
  mkdir -p "$DATA/install-rollback"
  backup="$(mktemp -d "$DATA/install-rollback/before-Tacit.XXXXXX")"
  mkdir "$staging/verify-backup"
  ditto -c -k --sequesterRsrc --keepParent "$LEGACY" "$backup/Record Anything.app.zip"
  ditto -x -k "$backup/Record Anything.app.zip" "$staging/verify-backup"
  codesign --verify --strict "$staging/verify-backup/Record Anything.app"
  printf '%s\n' "$LEGACY" > "$backup/application-path"
  cp -Rp "$staging/LaunchAgents" "$staging/launch-agents" "$backup"
  cp -p "$staging/loaded-jobs" "$backup/loaded-jobs"
  if [ -f "$staging/collector.json" ]; then cp -p "$staging/collector.json" "$backup/collector.json"; fi
  printf '%s\n' "$backup"
)

BUN="$(command -v bun || true)"
[ -n "$BUN" ] || { local_line "需要先安装 bun：curl -fsSL https://bun.sh/install | bash，装好后重新打开终端再运行 ./install.sh" "Install Bun with curl -fsSL https://bun.sh/install | bash, then reopen your terminal and run ./install.sh again."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { local_line "需要先安装 Xcode 命令行工具：运行 xcode-select --install，装好后再运行 ./install.sh" "Install the Xcode command-line tools with xcode-select --install, then run ./install.sh again."; exit 1; }
tacit_check_destination "$APP"
mkdir -p "$APP_DIR"
cd "$REPO"

step "$(local_text "安装依赖" "Install dependencies")"
"$BUN" install --frozen-lockfile
step "$(local_text "构建网页" "Build the web view")"
"$BUN" x vite build --config web/vite.config.ts --logLevel warn
step "$(local_text "下载并校验本机音频库" "Download and verify the local audio library")"
scripts/fetch-audio-lib.sh
step "$(local_text "构建并签名采集端" "Build and sign the recorder")"
collector/build.sh

step "$(local_text "准备安装包" "Prepare the app bundle")"
staging="$(mktemp -d "$APP_DIR/.tacit-install.XXXXXX")"
previous_app="$staging.previous.app"
switching=0
setup_started=0
trap 'finish_install "$?"' EXIT
trap 'exit 1' HUP INT TERM
ditto "collector/build/Tacit.app" "$staging/Tacit.app"
codesign --verify --deep --strict "$staging/Tacit.app"
snapshot_services
backup=""
legacy_exec=""
legacy_worker=""
if tacit_owns_bundle "$LEGACY"; then
  # macOS 权限取决于旧的签名要求；确认新包满足该要求，再切换安装。
  old_requirement="$(codesign -d -r- "$LEGACY" 2>&1 | sed -n 's/^designated => //p')"
  if [ -z "$old_requirement" ] || ! codesign --verify -R="$old_requirement" "$staging/Tacit.app"; then
    local_line "安装包不符合旧应用的签名要求，停止升级以保留系统权限。" "The new app does not meet the previous signing requirement. Upgrade stopped to preserve system permissions." >&2
    exit 1
  fi
  backup="$(save_rename_backup)"
  printf "$(local_text '回滚备份：%s\n' 'Rollback backup: %s\n')" "$backup"
  legacy_exec="$LEGACY/Contents/MacOS/Collector"
  legacy_worker="$LEGACY/Contents/MacOS/ra-audio-worker"
fi

switching=1
step "$(local_text "停止旧进程" "Stop previous processes")"
# 先让采集端完成收尾；它退出前后台服务必须继续接收最后一批记录。
COLLECTOR_PIDS="$(tacit_processes "$APP/Contents/MacOS/Tacit" "$legacy_exec")"
launchctl bootout "$DOMAIN/dev.record-anything.collector" 2>/dev/null || true
tacit_stop_processes "$COLLECTOR_PIDS"
tacit_stop_processes "$(tacit_processes "$APP/Contents/MacOS/ra-audio-worker" "$legacy_worker")"
for l in distill hub; do launchctl bootout "$DOMAIN/dev.record-anything.$l" 2>/dev/null || true; done

step "$(local_text "安装采集端到 $APP" "Install the recorder at $APP")"
tacit_check_destination "$APP"
if [ -d "$APP" ]; then mv "$APP" "$previous_app"; fi
mv "$staging/Tacit.app" "$APP"

step "$(local_text "初始化数据、连接 AI 工具并启动后台服务" "Prepare data and AI tool connections, then start the background service")"
# 与安装包首次打开走同一套准备流程（hub/src/setup.ts）。
if [ "${RA_NO_DISTILL:-0}" = 1 ]; then NO_DISTILL=--no-distill; else NO_DISTILL=""; fi
setup_started=1
if [ -x "$APP/Contents/MacOS/Tacit" ]; then
  "$APP/Contents/MacOS/Tacit" --initialize-language --data-dir "$DATA"
fi
"$APP/Contents/Helpers/Tacit" "$RUNTIME/hub/src/cli.ts" setup --app "$APP" --install $NO_DISTILL
if [ -n "$backup" ]; then
  # 新启动项加载后再撤下旧路径，避免相同包标识的两个应用同时留在“应用程序”。
  mv "$LEGACY" "$staging/previous.bundle"
fi
switching=0
rm -rf "$previous_app"

step "$(local_text "装好了" "Installation complete")"
if [ "$tacit_lang" = zh ]; then
cat <<MSG
1. 屏幕右上角的菜单栏里出现了 Tacit 图标。第一次运行时，macOS 会请你在“辅助功能”里允许它，打开后才能记录屏幕上的文字。
2. 点这个图标，从面板里打开 Tacit。时间线顶部会列出还差的几步：打开系统权限、确认 AI 能整理记录、接入 Claude Code 或 Codex。
3. 建议备份密钥：设置 → 维护 → 密钥备份。记录都加了密，密钥丢了就打不开。

数据存在 $DATA
以后更新：git pull && ./install.sh　卸载：./uninstall.sh
MSG
else
cat <<MSG
1. Look for the Tacit icon in the menu bar. On the first run, allow Tacit under Accessibility in System Settings so it can record screen text.
2. Open Tacit from the menu bar. The setup checklist at the top of Timeline shows which permissions, AI model connection, and AI tool connections still need attention.
3. Back up your keys in Settings → Maintenance → Key backup so you can recover your encrypted records.

Data is stored in $DATA
Update with git pull && ./install.sh. Uninstall with ./uninstall.sh.
MSG
fi
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo
  local_line "没找到 Claude Code 或 Codex。整理记录默认用本机已登录的 Claude Code，也可以在设置 → AI 模型里改用 API。" "Claude Code and Codex were not found. Sign in to Claude Code to summarize records with the default model, or choose an API in Settings → AI models."
fi
