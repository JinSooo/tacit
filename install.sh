#!/bin/sh
# 从源码安装 record-anything：构建网页和采集端，注册 hub、提炼与采集端开机自启（launchd）。
# 重复运行就是升级（git pull && ./install.sh）。卸载：./uninstall.sh
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/scripts/mac-app.sh"
DATA="$HOME/Library/Application Support/record-anything"
AGENTS="$HOME/Library/LaunchAgents"
# 关闭登录启动时定义保存在数据目录；升级沿用选择，仍启动本次安装后的服务。
if [ -f "$DATA/launch-agents/dev.record-anything.collector.plist" ]; then AGENTS="$DATA/launch-agents"; fi
APP_DIR="$(tacit_install_dir /Applications "$HOME/Applications")"
APP="$APP_DIR/Tacit.app"
LEGACY="$APP_DIR/Record Anything.app"
RUNTIME="$APP/Contents/Resources/runtime"
DOMAIN="gui/$(id -u)"
step() { printf '\n== %s\n' "$1"; }

save_rename_backup() (
  set -eu
  umask 077
  mkdir -p "$DATA/install-rollback"
  backup="$(mktemp -d "$DATA/install-rollback/before-Tacit.XXXXXX")"
  mkdir "$backup/LaunchAgents" "$backup/launch-agents" "$staging/verify-backup"
  ditto -c -k --sequesterRsrc --keepParent "$LEGACY" "$backup/Record Anything.app.zip"
  ditto -x -k "$backup/Record Anything.app.zip" "$staging/verify-backup"
  codesign --verify --strict "$staging/verify-backup/Record Anything.app"
  printf '%s\n' "$LEGACY" > "$backup/application-path"
  : > "$backup/loaded-jobs"
  for job in collector hub distill; do
    file="dev.record-anything.$job.plist"
    if [ -f "$HOME/Library/LaunchAgents/$file" ]; then
      cp -p "$HOME/Library/LaunchAgents/$file" "$backup/LaunchAgents/$file"
    fi
    if [ -f "$DATA/launch-agents/$file" ]; then
      cp -p "$DATA/launch-agents/$file" "$backup/launch-agents/$file"
    fi
    if launchctl print "$DOMAIN/dev.record-anything.$job" >/dev/null 2>&1; then
      printf '%s\n' "$job" >> "$backup/loaded-jobs"
    fi
  done
  if [ -f "$DATA/collector.json" ]; then cp -p "$DATA/collector.json" "$backup/collector.json"; fi
  printf '%s\n' "$backup"
)

# 提炼 plist 辅助函数：可单独提取，在临时目录验证，不执行安装流程。
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
distill_path() {
  python3 -I - "$BUN" "$(command -v codex || true)" "$(command -v claude || true)" "$HOME" <<'PY'
import os, sys
bun, codex, claude, home = sys.argv[1:]
system = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
fallback = [os.path.join(home, p) for p in (
    ".local/share/mise/shims", ".local/bin", ".bun/bin", ".npm-global/bin",
)] + system

def temporary(path):
    return (path.startswith(("/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"))
            or "-shims" in path)

def directories(path, name):
    real = os.path.realpath(path)
    if not os.path.isfile(real) or not os.access(real, os.X_OK) or temporary(real):
        return None
    # 优先保留用户安装的稳定入口；升级只改变链接目标，不把 PATH 钉在旧版本目录。
    entry_dir = os.path.dirname(os.path.abspath(path))
    if not temporary(os.path.abspath(path)) and os.path.basename(path) == name:
        return [entry_dir]
    # 临时 shim 才退到真实目录；npm 的 cli.js 不是同名可执行入口。
    real_dir = os.path.dirname(real)
    entry = os.path.join(real_dir, name)
    if os.path.isfile(entry) and os.access(entry, os.X_OK) and os.path.realpath(entry) == real:
        return [real_dir]
    return None

paths = []
for name, found in (("codex", codex), ("claude", claude)):
    if not found:
        print(f"没找到 {name}，先跳过。以后装好并登录 {name}，再运行一次 ./install.sh。", file=sys.stderr)
        continue
    dirs = directories(found, name)
    if dirs is None:
        for directory in fallback:
            candidate = os.path.join(directory, name)
            if not temporary(candidate):
                dirs = directories(candidate, name)
                if dirs is not None:
                    break
    if dirs is None:
        sys.exit(f"{name} 仅有临时 shim 或无效入口，未找到稳定可执行文件；请安装到 ~/.local/share/mise/shims、~/.local/bin 或 /opt/homebrew/bin 等稳定位置后重试。")
    paths.extend(dirs)
paths.extend([os.path.dirname(bun)] + system)
print(":".join(dict.fromkeys(paths)))
PY
}
write_distill_plist() {
  cat > "$AGENTS/dev.record-anything.distill.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.record-anything.distill</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$BUN")</string><string>$(xml "$RUNTIME/hub/src/cli.ts")</string><string>distill</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml "$RUNTIME")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(xml "$DISTILL_PATH")</string>
  </dict>
  <key>StandardOutPath</key><string>$(xml "$DATA/logs/distill.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$DATA/logs/distill.log")</string>
</dict></plist>
PLIST
}
# 提炼 plist 辅助函数结束。

# 音频资源辅助函数：下载只进入 staging，校验后再原子替换。
audio_sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
audio_download() (
  target="$1"; expected="$2"; url="$3"
  if audio_sha_ok "$target" "$expected"; then return; fi
  mkdir -p "$(dirname "$target")"
  stage="$(mktemp "${target}.download.XXXXXX")"
  trap 'rm -f "$stage"' EXIT HUP INT TERM
  if ! curl -fL --retry 3 "$url" -o "$stage"; then rm -f "$stage"; return 1; fi
  if ! audio_sha_ok "$stage" "$expected"; then
    rm -f "$stage"; echo "语音模型 sha256 不符：$target" >&2; return 1
  fi
  mv "$stage" "$target"
)
install_audio_resources() (
  set -eu
  base="https://github.com/k2-fsa/sherpa-onnx/releases/download"
  models="$DATA/models"
  mkdir -p "$models"
  audio_download "$models/silero_vad.onnx" 9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6 "$base/asr-models/silero_vad.onnx"
  speaker="3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
  audio_download "$models/$speaker" 1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b "$base/speaker-recongition-models/$speaker"
  model_sha=c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
  tokens_sha=f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc
  staging="$(mktemp -d "$models/.install.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT HUP INT TERM
  if ! audio_sha_ok "$models/sense-voice/model.int8.onnx" "$model_sha" || ! audio_sha_ok "$models/sense-voice/tokens.txt" "$tokens_sha"; then
    archive=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
    curl -fL --retry 3 "$base/asr-models/$archive.tar.bz2" -o "$staging/sense.tar.bz2"
    tar -xjf "$staging/sense.tar.bz2" -C "$staging" "$archive/model.int8.onnx" "$archive/tokens.txt"
    audio_sha_ok "$staging/$archive/model.int8.onnx" "$model_sha" && audio_sha_ok "$staging/$archive/tokens.txt" "$tokens_sha" || { echo "SenseVoice 模型 sha256 不符" >&2; exit 1; }
    mkdir -p "$models/sense-voice"
    mv "$staging/$archive/model.int8.onnx" "$models/sense-voice/model.int8.onnx"
    mv "$staging/$archive/tokens.txt" "$models/sense-voice/tokens.txt"
  fi
  library=sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib
  vendor="$REPO/collector/vendor"
  capi_sha=2a169fe29c7e75168cc308b0d5b7f9085efebbb3a7f812d46c3a983d6788759f
  ort_sha=3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b
  header_sha=5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
  if ! audio_sha_ok "$vendor/$library/lib/libsherpa-onnx-c-api.dylib" "$capi_sha" || ! audio_sha_ok "$vendor/$library/lib/libonnxruntime.dylib" "$ort_sha"; then
    curl -fL --retry 3 "$base/v2.0.1/$library.tar.bz2" -o "$staging/library.tar.bz2"
    tar -xjf "$staging/library.tar.bz2" -C "$staging" "$library"
    audio_sha_ok "$staging/$library/lib/libsherpa-onnx-c-api.dylib" "$capi_sha" && audio_sha_ok "$staging/$library/lib/libonnxruntime.dylib" "$ort_sha" || { echo "sherpa-onnx 库 sha256 不符" >&2; exit 1; }
    mkdir -p "$vendor"
    rm -rf "$vendor/$library"
    mv "$staging/$library" "$vendor/$library"
  fi
  # 发布包未带头文件时，取与 dylib 一致的 v2.0.1 C API 头文件。
  if ! audio_sha_ok "$vendor/include/sherpa-onnx/c-api/c-api.h" "$header_sha"; then
    mkdir -p "$vendor/include/sherpa-onnx/c-api"
    curl -fL --retry 3 "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h" -o "$staging/c-api.h"
    audio_sha_ok "$staging/c-api.h" "$header_sha" || { echo "sherpa-onnx 头文件 sha256 不符" >&2; exit 1; }
    mv "$staging/c-api.h" "$vendor/include/sherpa-onnx/c-api/c-api.h"
  fi
)
# 音频资源辅助函数结束。

BUN="$(command -v bun || true)"
[ -n "$BUN" ] || { echo "需要先安装 bun：curl -fsSL https://bun.sh/install | bash，装好后重新打开终端再运行 ./install.sh"; exit 1; }
if [ "${RA_NO_DISTILL:-0}" != 1 ]; then DISTILL_PATH="$(distill_path)"; fi
xcode-select -p >/dev/null 2>&1 || { echo "需要先安装 Xcode 命令行工具：运行 xcode-select --install，装好后再运行 ./install.sh"; exit 1; }
tacit_check_destination "$APP"
mkdir -p "$APP_DIR"
cd "$REPO"

step "安装依赖"
"$BUN" install --frozen-lockfile
step "构建网页"
"$BUN" x vite build --config web/vite.config.ts --logLevel warn
step "下载并校验语音模型和本机音频库"
install_audio_resources
step "构建并签名采集端"
collector/build.sh

step "准备安装包"
staging="$(mktemp -d "$APP_DIR/.tacit-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM
ditto "collector/build/Tacit.app" "$staging/Tacit.app"
codesign --verify --strict "$staging/Tacit.app"
backup=""
legacy_exec=""
legacy_worker=""
if tacit_owns_bundle "$LEGACY"; then
  # macOS 权限取决于旧的签名要求；确认新包满足该要求，再切换安装。
  old_requirement="$(codesign -d -r- "$LEGACY" 2>&1 | sed -n 's/^designated => //p')"
  if [ -z "$old_requirement" ] || ! codesign --verify -R="$old_requirement" "$staging/Tacit.app"; then
    echo "安装包不符合旧应用的签名要求，停止升级以保留系统权限。" >&2
    exit 1
  fi
  backup="$(save_rename_backup)"
  printf '回滚备份：%s\n' "$backup"
  legacy_exec="$LEGACY/Contents/MacOS/Collector"
  legacy_worker="$LEGACY/Contents/MacOS/ra-audio-worker"
fi

step "停止旧进程"
# 先让采集端完成收尾；它退出前后台服务必须继续接收最后一批记录。
COLLECTOR_PIDS="$(tacit_processes "$APP/Contents/MacOS/Tacit" "$legacy_exec")"
launchctl bootout "$DOMAIN/dev.record-anything.collector" 2>/dev/null || true
tacit_stop_processes "$COLLECTOR_PIDS"
tacit_stop_processes "$(tacit_processes "$APP/Contents/MacOS/ra-audio-worker" "$legacy_worker")"
for l in distill hub; do launchctl bootout "$DOMAIN/dev.record-anything.$l" 2>/dev/null || true; done
if [ "${RA_NO_DISTILL:-0}" = 1 ]; then rm -f "$AGENTS/dev.record-anything.distill.plist"; fi

step "安装采集端到 $APP"
tacit_check_destination "$APP"
rm -rf "$APP"
mv "$staging/Tacit.app" "$APP"

step "初始化数据目录和数据库密钥（钥匙串）"
mkdir -p "$DATA/logs"
chmod 700 "$DATA"
"$BUN" "$RUNTIME/hub/src/cli.ts" init >/dev/null
# 采集端配置：只更新仓库和 bun 的路径，保留用户改过的其他项。
python3 -I - "$DATA/collector.json" "$RUNTIME" "$BUN" <<'PY'
import json, os, sys
path, repo, bun = sys.argv[1:4]
try: conf = json.load(open(path))
except Exception: conf = {}
conf.update(repo=repo, bun=bun)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    os.fchmod(f.fileno(), 0o600)
    f.write(json.dumps(conf, ensure_ascii=False, indent=2) + "\n")
PY

step "更新已连接 AI 工具的运行路径并停用冻结来源"
"$BUN" "$RUNTIME/hub/src/relocate-install.ts" "$RUNTIME" "$BUN"
for source in git shell files clipboard; do
  /usr/bin/defaults write dev.record-anything.collector "source.$source.enabled" -bool false
done

step "更新启动配置（保留登录启动选择）"
mkdir -p "$AGENTS"
cat > "$AGENTS/dev.record-anything.hub.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.record-anything.hub</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$BUN")</string><string>$(xml "$RUNTIME/hub/src/cli.ts")</string><string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml "$RUNTIME")</string>
  <key>EnvironmentVariables</key><dict>
    <!-- 设置页的"测试连接"由中枢直接调用模型，要和提炼进程一样能找到 codex、claude。 -->
    <key>PATH</key><string>$(xml "${DISTILL_PATH:-$(dirname "$BUN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}")</string>
  </dict>
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
  <key>ProgramArguments</key><array><string>$(xml "$APP/Contents/MacOS/Tacit")</string></array>
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
# 端口和中枢同一来源：数据目录的 hub.json（设置页可改），没有或无效时 47823。
PORT="$(plutil -extract port raw -o - "$DATA/hub.json" 2>/dev/null || true)"
case "$PORT" in ''|*[!0-9]*) PORT=47823 ;; esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then PORT=47823; fi
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 || { echo "后台服务没能启动，原因写在 $DATA/logs/hub.log"; exit 1; }
if [ "${RA_NO_DISTILL:-0}" != 1 ]; then
  write_distill_plist
  launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.distill.plist"
else
  echo "RA_NO_DISTILL=1：已停用提炼自启并移除 plist。"
fi
launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.collector.plist"
if [ -n "$backup" ]; then
  # 新启动项加载后再撤下旧路径，避免相同包标识的两个应用同时留在“应用程序”。
  mv "$LEGACY" "$staging/previous.bundle"
fi

step "装好了"
cat <<MSG
1. 屏幕右上角的菜单栏里出现了 Tacit 图标。第一次运行时，macOS 会请你在“辅助功能”里允许它，打开后才能记录屏幕上的文字。
2. 点这个图标，从面板里打开 Tacit。时间线顶部会列出还差的几步：打开系统权限、确认 AI 能整理记录、接入 Claude Code 或 Codex。
3. 建议备份密钥：设置 → 维护 → 密钥备份。记录都加了密，密钥丢了就打不开。

数据存在 $DATA
以后更新：git pull && ./install.sh　卸载：./uninstall.sh
MSG
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo
  echo "没找到 Claude Code 或 Codex。整理记录默认用本机已登录的 Claude Code，也可以在设置 → AI 模型里改用 API。"
fi
