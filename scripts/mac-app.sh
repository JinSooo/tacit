#!/bin/sh
# 安装和卸载只处理本应用在两个标准安装位置的包及进程。

tacit_owns_bundle() {
  [ -d "$1" ] && [ ! -L "$1" ] &&
    [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" = dev.record-anything.collector ]
}

tacit_install_dir() {
  for dir in "$1" "$2"; do
    if tacit_owns_bundle "$dir/Tacit.app" || tacit_owns_bundle "$dir/Record Anything.app"; then
      printf '%s\n' "$dir"
      return
    fi
  done
  if [ -w "$1" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

tacit_check_destination() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    tacit_owns_bundle "$1" || { printf '安装位置已被其他应用占用：%s\n' "$1" >&2; return 1; }
  fi
}

tacit_processes() {
  # ps 的命令列不拆路径中的空格，只匹配所指定的两个应用包内的可执行文件。
  /bin/ps -axww -o pid=,command= | TACIT_PROCESS_A="$1" TACIT_PROCESS_B="$2" awk '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      a = ENVIRON["TACIT_PROCESS_A"]
      b = ENVIRON["TACIT_PROCESS_B"]
      if ((a != "" && ($0 == a || index($0, a " ") == 1)) ||
          (b != "" && ($0 == b || index($0, b " ") == 1))) print pid
    }'
}

tacit_stop_processes() {
  for pid in $1; do
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Tacit 进程 %s 尚未退出，停止操作以保留待发送记录。\n' "$pid" >&2
      return 1
    fi
  done
}
