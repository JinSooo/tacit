# 手动 source 本文件即可；重复加载不会重复安装钩子。
autoload -Uz add-zsh-hook
zmodload zsh/datetime 2>/dev/null || return 0

typeset -g _ra_shell_log=${RA_SHELL_LOG:-$HOME/Library/Application Support/record-anything/buffer/shell.jsonl}
# 只在加载时创建目录；不改变调用者的 umask。
(umask 077; command mkdir -p -- "${_ra_shell_log:h}" && : >> "$_ra_shell_log") 2>/dev/null || true

_ra_shell_quote() {
  emulate -L zsh
  local value=$1 char oct escaped
  integer i
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  for ((i = 0; i < 32; i++)); do
    printf -v oct '%03o' $i
    printf -v char '%b' "\\$oct"
    printf -v escaped '\\u%04x' $i
    value=${value//$char/$escaped}
  done
  REPLY=\"$value\"
}

_ra_shell_preexec() {
  emulate -L zsh
  typeset -g _ra_shell_command='' _ra_shell_cwd=''
  typeset -gi _ra_shell_started=0
  [[ $1 == ' '* ]] && return 0
  typeset -g _ra_shell_command=$1 _ra_shell_cwd=$PWD
  (( _ra_shell_started = EPOCHREALTIME * 1000 ))
  return 0
}

_ra_shell_precmd() {
  local command_status=$?
  emulate -L zsh
  (( _ra_shell_started > 0 )) || return 0
  local started=$_ra_shell_started command=$_ra_shell_command cwd=$_ra_shell_cwd
  typeset -gi _ra_shell_started=0
  local REPLY command_json cwd_json
  integer duration
  (( duration = EPOCHREALTIME * 1000 - started ))
  ((duration < 0)) && duration=0
  _ra_shell_quote "$command"
  command_json=$REPLY
  _ra_shell_quote "$cwd"
  cwd_json=$REPLY
  # 只使用内建命令；独立作用域的 umask 不会影响用户后续命令。
  (umask 077; print -r -- "{\"start_ms\":$started,\"duration_ms\":$duration,\"exit_code\":$command_status,\"cwd\":$cwd_json,\"command\":$command_json,\"pid\":$$}" >> "$_ra_shell_log") 2>/dev/null || true
  return 0
}

add-zsh-hook -d preexec _ra_shell_preexec
add-zsh-hook -d precmd _ra_shell_precmd
add-zsh-hook preexec _ra_shell_preexec
add-zsh-hook precmd _ra_shell_precmd
return 0
