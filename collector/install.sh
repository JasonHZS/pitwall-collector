#!/bin/sh
# 安装 / 卸载 pitwall 的事件采集。
#
#   collector/install.sh install   [claude-code] [codex] [cursor] [pi] [devin]   # 不带参数 = 全部
#   collector/install.sh uninstall [claude-code] [codex] [cursor] [pi] [devin]
#
# install：把 hook 脚本和查看工具复制到 ~/.pitwall/bin/，然后在各 agent 的全局配置里
# 登记 pitwall 的 hook：已登记且一致的条目原样保留（位置不动），缺失或过时的才替换，
# 重复执行结果不变；其它 hook 原样保留。
# 任何 agent 配置被改动前，原文件先备份到 ~/.pitwall/backups/<时间>/，只保留最近 10 份。
set -eu

# readlink -f：经 Homebrew 的 pitwall-collector 软链调用时，仍定位到 App 内的 collector 目录。
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
JQ=/usr/bin/jq
PW_HOME=${PITWALL_HOME:-$HOME/.pitwall}
BIN_DIR="$PW_HOME/bin"
HOOK="$BIN_DIR/pitwall-hook"
BACKUP_DIR="$PW_HOME/backups/$(date +%Y%m%d-%H%M%S)"
BACKUP_KEEP=10

CLAUDE_CFG="$HOME/.claude/settings.json"
CODEX_CFG="$HOME/.codex/hooks.json"
CURSOR_CFG="$HOME/.cursor/hooks.json"
PI_EXT="$HOME/.pi/agent/extensions/pitwall.ts"
DEVIN_CFG="$HOME/.config/devin/config.json"

CLAUDE_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied","Notification","Elicitation","Stop","StopFailure"]'
CLAUDE_TOOL_EVENTS='["PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied"]'
CODEX_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"]'
# Cursor 的 before* 权限类 hook（beforeShellExecution 等）带决策语义，刻意不注册。
CURSOR_EVENTS='["sessionStart","sessionEnd","beforeSubmitPrompt","postToolUse","postToolUseFailure","stop"]'
# Devin 只认这 8 个事件：hooks 里出现任何别的事件名（或 async 等未知字段的风险），
# Devin 会整段忽略 hooks 设置——连同用户自己的 hook。所以这里只登记这 8 个、不写 async / matcher。
DEVIN_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Stop","PostCompaction"]'

# pitwall 的 handler 以命令里含 pitwall-hook 识别；Claude/Codex 是两层结构，Cursor 是一层。
JQ_DEFS='
def ours: (.command // "") | tostring | contains("pitwall-hook");
def strip_nested:
  if (.hooks | type) == "object" then
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))))
               | with_entries(select((.value | length) > 0)))
  else . end;
def strip_flat:
  if (.hooks | type) == "object" then
    .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select((.value | length) > 0)))
  else . end;
# ensure_*：该事件里 pitwall 的条目已与期望一致就原样保留（包括位置），否则删掉旧条目再追加。
# 这样别的工具在我们之后追加的 hook 不会让重复安装调换顺序。prune_*：清掉不再登记的事件里的旧条目。
def without_ours_nested: map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0));
def ensure_nested($e; $entry):
  if (.hooks | type) == "object" and [.hooks[$e][]? | select(any(.hooks[]?; ours))] == [$entry] then .
  else .hooks[$e] = (((.hooks[$e] // []) | without_ours_nested) + [$entry]) end;
def prune_nested($events):
  if (.hooks | type) == "object" then
    .hooks |= with_entries(.key as $k | if ($events | index($k)) == null then .value |= without_ours_nested else . end
                           | select((.value | length) > 0))
  else . end;
def ensure_flat($e; $entry):
  if (.hooks | type) == "object" and [.hooks[$e][]? | select(ours)] == [$entry] then .
  else .hooks[$e] = (((.hooks[$e] // []) | map(select(ours | not))) + [$entry]) end;
def prune_flat($events):
  if (.hooks | type) == "object" then
    .hooks |= with_entries(.key as $k | if ($events | index($k)) == null then .value |= map(select(ours | not)) else . end
                           | select((.value | length) > 0))
  else . end;
'

log() { printf '%s\n' "$*"; }

count_ours() {
  "$JQ" '[.. | objects | select(has("command")) | select(.command | tostring | contains("pitwall-hook"))] | length' "$1" 2>/dev/null || echo 0
}

# edit_json <文件> <jq 程序> [jq 参数...]
# 文件不存在按 {} 处理；不是合法 JSON 就拒绝修改；内容没变（忽略格式与缩进）就不写盘。
edit_json() {
  file=$1 prog=$2
  shift 2
  if [ -e "$file" ] && ! "$JQ" empty "$file" 2>/dev/null; then
    log "  ✗ $file 不是合法 JSON，未修改"
    return 1
  fi
  tmp="$file.pitwall.tmp"
  # jq 出错或产出不是对象时绝不写回：调用方在 && 链里，set -e 不会替我们中止。
  if ! { if [ -e "$file" ]; then cat "$file"; else printf '{}'; fi | "$JQ" "$@" "$JQ_DEFS $prog" > "$tmp"; } ||
     ! "$JQ" -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "  ✗ 生成 $file 的新内容失败，未修改"
    return 1
  fi
  if [ -e "$file" ] && [ "$("$JQ" -S -c . "$tmp")" = "$("$JQ" -S -c . "$file")" ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$file" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -p "$file" "$BACKUP_DIR/$(printf '%s' "${file#"$HOME"/}" | sed 's/^\.//' | tr '/' '_')"
  else
    mkdir -p "$(dirname "$file")"
  fi
  if [ -L "$file" ]; then
    cat "$tmp" > "$file" && rm -f "$tmp"          # 软链（dotfiles 管理）：写穿，不替换链接
  else
    [ -e "$file" ] && chmod "$(stat -f %Lp "$file")" "$tmp"
    mv "$tmp" "$file"
  fi
}

install_claude() {
  [ -d "$HOME/.claude" ] || { log "claude-code：未找到 ~/.claude，跳过"; return 0; }
  edit_json "$CLAUDE_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested($e;
          (if ($tool | index($e)) != null then {matcher: "*"} else {} end)
          + {hooks: [{type: "command", command: ($hook + " claude-code " + $e), async: true, timeout: 10}]}))' \
    --argjson events "$CLAUDE_EVENTS" --argjson tool "$CLAUDE_TOOL_EVENTS" --arg hook "$HOOK" &&
    log "claude-code：$CLAUDE_CFG 中 pitwall hook $(count_ours "$CLAUDE_CFG") 个（异步执行，不阻塞）"
}

# Codex 的 SessionEnd 不支持 async（会被改为同步执行并报「加载问题」），所以只给其它事件加 async。
install_codex() {
  [ -d "$HOME/.codex" ] || { log "codex：未找到 ~/.codex，跳过"; return 0; }
  edit_json "$CODEX_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested($e;
          {matcher: "", hooks: [{type: "command", command: ($hook + " codex " + $e)} + (if $e == "SessionEnd" then {} else {async: true} end)]}))' \
    --argjson events "$CODEX_EVENTS" --arg hook "$HOOK" &&
    log "codex：$CODEX_CFG 中 pitwall hook $(count_ours "$CODEX_CFG") 个（需在 Codex 里信任后才会运行）"
}

install_cursor() {
  [ -d "$HOME/.cursor" ] || { log "cursor：未找到 ~/.cursor，跳过"; return 0; }
  edit_json "$CURSOR_CFG" '
    (.version //= 1)
    | prune_flat($events)
    | reduce $events[] as $e (.; ensure_flat($e; {command: ($hook + " cursor " + $e), type: "command"}))' \
    --argjson events "$CURSOR_EVENTS" --arg hook "$HOOK" &&
    log "cursor：$CURSOR_CFG 中 pitwall hook $(count_ours "$CURSOR_CFG") 个"
}

install_pi() {
  [ -d "$HOME/.pi/agent" ] || { log "pi：未找到 ~/.pi/agent，跳过"; return 0; }
  mkdir -p "$(dirname "$PI_EXT")"
  # 这个文件是 pitwall 自己的扩展，不是用户配置：直接覆盖，不备份。
  install -m 644 "$here/pi/pitwall.ts" "$PI_EXT"
  log "pi：扩展已放到 ${PI_EXT}（新开的 Pi 会话生效，已开的会话可 /reload）"
}

# Devin 的 hook 是同步执行的（没有 async）；pitwall-hook 只做一次 jq 追加，并设 10 秒上限。
install_devin() {
  [ -d "$HOME/.config/devin" ] || { log "devin：未找到 ~/.config/devin，跳过"; return 0; }
  edit_json "$DEVIN_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested($e; {hooks: [{type: "command", command: ($hook + " devin " + $e), timeout: 10}]}))' \
    --argjson events "$DEVIN_EVENTS" --arg hook "$HOOK" &&
    log "devin：$DEVIN_CFG 中 pitwall hook $(count_ours "$DEVIN_CFG") 个（新开的 Devin 会话生效）"
  # 用户自己登记在其它事件名下的 hook 不归我们删，但它会让 Devin 忽略全部 hooks（包括我们的）。
  extra=$("$JQ" -r --argjson events "$DEVIN_EVENTS" '(.hooks // {}) | keys - $events | join(", ")' "$DEVIN_CFG" 2>/dev/null) || extra=''
  [ -z "$extra" ] || log "  ✗ devin：hooks 含 Devin 不认识的事件（$extra），Devin 会忽略全部 hooks；请手动移除这些事件"
}

uninstall_claude() {
  [ -e "$CLAUDE_CFG" ] || return 0
  edit_json "$CLAUDE_CFG" 'strip_nested | if .hooks == {} then del(.hooks) else . end' &&
    log "claude-code：已移除 pitwall hook"
}

uninstall_codex() {
  [ -e "$CODEX_CFG" ] || return 0
  edit_json "$CODEX_CFG" 'strip_nested | .hooks //= {}' && log "codex：已移除 pitwall hook"
}

uninstall_cursor() {
  [ -e "$CURSOR_CFG" ] || return 0
  edit_json "$CURSOR_CFG" 'strip_flat | .hooks //= {}' && log "cursor：已移除 pitwall hook"
}

uninstall_devin() {
  [ -e "$DEVIN_CFG" ] || return 0
  edit_json "$DEVIN_CFG" 'strip_nested | if .hooks == {} then del(.hooks) else . end' &&
    log "devin：已移除 pitwall hook"
}

uninstall_pi() {
  [ -e "$PI_EXT" ] || return 0
  rm -f "$PI_EXT" && log "pi：已移除扩展"
}

# 只清理本脚本建的 <日期>-<时间> 目录，按名字排序保留最新的 BACKUP_KEEP 份；其它文件不碰。
prune_backups() {
  dir="$PW_HOME/backups"
  [ -d "$dir" ] || return 0
  ls -1 "$dir" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort |
    awk -v keep="$BACKUP_KEEP" '{ name[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print name[i] }' |
    while read -r old; do rm -rf "${dir:?}/$old"; done
}

# Bilingual, unlike the rest of the output: this is what a first run without arguments shows.
usage() {
  name=$(basename "$0")
  cat <<EOF
Install or remove Pitwall's event collection.
安装或卸载 Pitwall 的事件采集。

  $name install   [claude-code] [codex] [cursor] [pi] [devin]   # no agents = all / 不带参数 = 全部
  $name uninstall [claude-code] [codex] [cursor] [pi] [devin]

install copies the hook scripts and the event viewer to ~/.pitwall/bin/ and registers Pitwall's
hooks in each agent's global config. Entries already up to date stay where they are, missing or
outdated ones are replaced, and other hooks are left alone; running it again changes nothing.
install：把 hook 脚本和查看工具复制到 ~/.pitwall/bin/，然后在各 agent 的全局配置里登记 pitwall 的
hook：已登记且一致的条目原样保留，缺失或过时的才替换，其它 hook 原样保留；重复执行结果不变。

Before any agent config is changed, the original is backed up to ~/.pitwall/backups/<time>/
(the 10 most recent are kept).
任何 agent 配置被改动前，原文件先备份到 ~/.pitwall/backups/<时间>/，只保留最近 10 份。
EOF
}

cmd=${1:-}
[ $# -gt 0 ] && shift
agents=${*:-claude-code codex cursor pi devin}

[ -x "$JQ" ] || { log "需要 /usr/bin/jq（macOS 15 起系统自带）"; exit 1; }

case "$cmd" in
  install)
    mkdir -p "$BIN_DIR" "$PW_HOME/events"
    install -m 755 "$here/bin/pitwall-hook" "$HOOK"
    install -m 755 "$here/bin/pitwall-events" "$BIN_DIR/pitwall-events"
    for a in $agents; do
      case $a in
        claude-code) install_claude ;;
        codex) install_codex ;;
        cursor) install_cursor ;;
        pi) install_pi ;;
        devin) install_devin ;;
        *) log "未知 agent：$a" ;;
      esac
    done
    prune_backups
    [ -d "$BACKUP_DIR" ] && log "原配置已备份到 $BACKUP_DIR"
    log ""
    log "事件写入 $PW_HOME/events/<agent>.jsonl，查看：$BIN_DIR/pitwall-events status | summary | tail -f | doctor"
    case " $agents " in
      *" codex "*) log "Codex 会拦下新 hook 等你审核：在 Codex 里打开 /hooks 信任 pitwall 的 hook（本脚本不会代签）。" ;;
    esac
    ;;
  uninstall)
    for a in $agents; do
      case $a in
        claude-code) uninstall_claude ;;
        codex) uninstall_codex ;;
        cursor) uninstall_cursor ;;
        pi) uninstall_pi ;;
        devin) uninstall_devin ;;
        *) log "未知 agent：$a" ;;
      esac
    done
    prune_backups
    [ -d "$BACKUP_DIR" ] && log "改动前的配置已备份到 $BACKUP_DIR"
    log "已采集的事件保留在 $PW_HOME/events/，需要时手动删除。"
    ;;
  *)
    usage
    exit 2
    ;;
esac
