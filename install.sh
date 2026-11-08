#!/bin/sh
# 从源码安装 record-anything：构建网页和采集端，注册 hub、提炼与采集端开机自启（launchd）。
# 重复运行就是升级（git pull && ./install.sh）。卸载：./uninstall.sh
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/Library/Application Support/record-anything"
AGENTS="$HOME/Library/LaunchAgents"
APP_DIR=/Applications; [ -w "$APP_DIR" ] || APP_DIR="$HOME/Applications"
APP="$APP_DIR/Record Anything.app"
DOMAIN="gui/$(id -u)"
step() { printf '\n== %s\n' "$1"; }

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
    # npm 等安装会把 codex 链接到 cli.js：真实目录之外还需保留同名入口。
    real_dir = os.path.dirname(real)
    entry = os.path.join(real_dir, name)
    if os.path.isfile(entry) and os.access(entry, os.X_OK) and os.path.realpath(entry) == real:
        return [real_dir]
    if not temporary(os.path.abspath(path)) and os.path.basename(path) == name:
        return [real_dir, os.path.dirname(os.path.abspath(path))]
    return None

paths = []
for name, found in (("codex", codex), ("claude", claude)):
    if not found:
        print(f"未找到 {name}，跳过其 PATH 目录；使用该 CLI 前请安装、登录并重新运行安装脚本。", file=sys.stderr)
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
    <string>$(xml "$BUN")</string><string>$(xml "$REPO/hub/src/cli.ts")</string><string>distill</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml "$REPO")</string>
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
[ -n "$BUN" ] || { echo "需要 bun：https://bun.sh"; exit 1; }
if [ "${RA_NO_DISTILL:-0}" != 1 ]; then DISTILL_PATH="$(distill_path)"; fi
xcode-select -p >/dev/null 2>&1 || { echo "需要 Xcode 命令行工具：xcode-select --install"; exit 1; }
cd "$REPO"

step "安装依赖"
"$BUN" install --frozen-lockfile
step "构建网页"
"$BUN" x vite build --config web/vite.config.ts --logLevel warn
step "下载并校验语音模型和本机音频库"
install_audio_resources
step "构建并签名采集端（固定的自签名证书，升级后系统权限不丢）"
collector/build.sh

step "停止旧进程"
for l in collector distill hub; do launchctl bootout "$DOMAIN/dev.record-anything.$l" 2>/dev/null || true; done
if [ "${RA_NO_DISTILL:-0}" = 1 ]; then rm -f "$AGENTS/dev.record-anything.distill.plist"; fi
pkill -f 'Record Anything.app/Contents/MacOS/Collector' 2>/dev/null || true
pkill -f 'Record Anything.app/Contents/MacOS/ra-audio-worker' 2>/dev/null || true

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
if [ "${RA_NO_DISTILL:-0}" != 1 ]; then
  write_distill_plist
  launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.distill.plist"
else
  echo "RA_NO_DISTILL=1：已停用提炼自启并移除 plist。"
fi
launchctl bootstrap "$DOMAIN" "$AGENTS/dev.record-anything.collector.plist"

step "完成"
cat <<MSG
- 菜单栏出现 Record Anything 图标；第一次运行会请求辅助功能权限。
- 打开 History：菜单里点"打开 History"，或运行 bun "$REPO/hub/src/cli.ts" open
- 记录终端命令：在 ~/.zshrc 里加一行
    source "$REPO/plugins/shell/hook.zsh"
- 语音模型：$DATA/models/；加密音频：$DATA/audio/（卸载保留）
- 日志：$DATA/logs/
- 提炼日志：$DATA/logs/distill.log；模型配置：$DATA/models.json
MSG
if [ ! -f "$DATA/models.json" ]; then echo "- models.json 不存在，提炼默认使用本机已登录的 claude CLI。"; fi
