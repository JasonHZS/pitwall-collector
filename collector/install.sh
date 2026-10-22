#!/bin/sh
# 安装 / 卸载 pitwall 的事件采集。
#
#   collector/install.sh install   [claude-code] [codex] [cursor] [pi] [devin] [opencode]   # 不带参数 = 全部
#   collector/install.sh uninstall [claude-code] [codex] [cursor] [pi] [devin] [opencode]
#
# install：把 hook 脚本和查看工具复制到 ~/.pitwall/bin/，然后在各 agent 的全局配置里
# 登记 pitwall 的 hook：已登记且一致的条目原样保留（位置不动），缺失或过时的才替换，
# 重复执行结果不变；其它 hook 原样保留。
# hook 配置被改动前会备份到 ~/.pitwall/backups/<时间>/，只保留最近 10 份；
# Pi 扩展与 OpenCode 插件是 Pitwall 自有文件，直接覆盖，不备份。
set -eu

# readlink -f：经 Homebrew 的 pitwall-collector 软链调用时，仍定位到 App 内的 collector 目录。
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
JQ=/usr/bin/jq
PW_HOME=${PITWALL_HOME:-$HOME/.pitwall}
BIN_DIR="$PW_HOME/bin"
HOOK="$BIN_DIR/pitwall-hook"
APPROVAL="$BIN_DIR/pitwall-approval"
BACKUP_DIR="$PW_HOME/backups/$(date +%Y%m%d-%H%M%S)"
BACKUP_KEEP=10

CLAUDE_CFG="$HOME/.claude/settings.json"
CODEX_CFG="$HOME/.codex/hooks.json"
CURSOR_CFG="$HOME/.cursor/hooks.json"
PI_EXT="$HOME/.pi/agent/extensions/pitwall.ts"
DEVIN_CFG="$HOME/.config/devin/config.json"
# OpenCode 插件目录：server.ts 在后台服务中采集事件，tui.ts 在每个终端客户端中报告所显示的会话。
OPENCODE_PLUGIN="$HOME/.config/opencode/plugins/pitwall"
# 0.6 及更早版本安装的单文件插件；与目录插件同 ID，必须移除，否则服务端报重复插件。
OPENCODE_LEGACY_PLUGIN="$HOME/.config/opencode/plugins/pitwall.ts"

CLAUDE_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied","Notification","Elicitation","Stop","StopFailure"]'
CLAUDE_TOOL_EVENTS='["PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied"]'
CODEX_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop","Interrupt"]'
# Cursor 的 before* 权限类 hook（beforeShellExecution 等）带决策语义，刻意不注册。
CURSOR_EVENTS='["sessionStart","sessionEnd","beforeSubmitPrompt","postToolUse","postToolUseFailure","stop"]'
# Devin 只认这 8 个事件：hooks 里出现任何别的事件名（或 async 等未知字段的风险），
# Devin 会整段忽略 hooks 设置——连同用户自己的 hook。所以这里只登记这 8 个、不写 async；
# matcher 是正则，只在提问 hook 上写精确的工具名（Claude 格式的 "*" 不是合法正则）。
DEVIN_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Stop","PostCompaction"]'

# pitwall 的 handler 以命令里含 pitwall-hook / pitwall-approval 识别；Claude/Codex 是两层结构，Cursor 是一层。
JQ_DEFS='
def ours: (.command // "") | tostring | (contains("pitwall-hook") or contains("pitwall-approval"));
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
def ensure_nested_all($e; $entries):
  if (.hooks | type) == "object" and [.hooks[$e][]? | select(any(.hooks[]?; ours))] == $entries then .
  else .hooks[$e] = (((.hooks[$e] // []) | without_ours_nested) + $entries) end;
def ensure_nested($e; $entry): ensure_nested_all($e; [$entry]);
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
# Each message in English, then Chinese.
say() { printf '%s\n%s\n' "$1" "$2"; }

count_ours() {
  "$JQ" '[.. | objects | select(has("command")) | select(.command | tostring | (contains("pitwall-hook") or contains("pitwall-approval")))] | length' "$1" 2>/dev/null || echo 0
}

# edit_json <文件> <jq 程序> [jq 参数...]
# 文件不存在按 {} 处理；不是合法 JSON 就拒绝修改；内容没变（忽略格式与缩进）就不写盘。
edit_json() {
  file=$1 prog=$2
  shift 2
  if [ -e "$file" ] && ! "$JQ" empty "$file" 2>/dev/null; then
    say "  ✗ $file is not valid JSON; left unchanged" "  ✗ $file 不是合法 JSON，未修改"
    return 1
  fi
  tmp="$file.pitwall.tmp"
  # jq 出错或产出不是对象时绝不写回：调用方在 && 链里，set -e 不会替我们中止。
  if ! { if [ -e "$file" ]; then cat "$file"; else printf '{}'; fi | "$JQ" "$@" "$JQ_DEFS $prog" > "$tmp"; } ||
     ! "$JQ" -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    say "  ✗ could not build the new contents of $file; left unchanged" "  ✗ 生成 $file 的新内容失败，未修改"
    return 1
  fi
  if [ -e "$file" ] && [ "$("$JQ" -S -c . "$tmp")" = "$("$JQ" -S -c . "$file")" ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$file" ]; then
    # 备份失败就不改：调用方在 || / && 里，set -e 不会替我们中止。
    if ! { mkdir -p "$BACKUP_DIR" &&
           cp -p "$file" "$BACKUP_DIR/$(printf '%s' "${file#"$HOME"/}" | sed 's/^\.//' | tr '/' '_')"; }; then
      rm -f "$tmp"
      say "  ✗ could not back up $file; left unchanged" "  ✗ 备份 $file 失败，未修改"
      return 1
    fi
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

# PermissionRequest 另登记一个同步的 pitwall-approval：Claude Code 照常显示终端审批框，同时把请求交给
# Pitwall；Pitwall 没在运行时它立即退出、不输出。timeout 略长于脚本自己的 900 秒上限。
install_claude() {
  [ -d "$HOME/.claude" ] || { say "claude-code: ~/.claude not found, skipped" "claude-code：未找到 ~/.claude，跳过"; return 0; }
  edit_json "$CLAUDE_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested_all($e;
          [(if ($tool | index($e)) != null then {matcher: "*"} else {} end)
           + {hooks: [{type: "command", command: ($hook + " claude-code " + $e), async: true, timeout: 10}]}]
          + (if $e == "PermissionRequest"
             then [{matcher: "*", hooks: [{type: "command", command: ($approval + " claude-code"), timeout: 960}]}]
             else [] end)))' \
    --argjson events "$CLAUDE_EVENTS" --argjson tool "$CLAUDE_TOOL_EVENTS" --arg hook "$HOOK" --arg approval "$APPROVAL" && {
    n=$(count_ours "$CLAUDE_CFG")
    say "claude-code: $n pitwall hooks in $CLAUDE_CFG (the approval hook answers only when you click in Pitwall)" "claude-code：$CLAUDE_CFG 中 pitwall hook $n 个（审批 hook 只在你于 Pitwall 中点击时作答）"
  }
}

# Codex 的 SessionEnd 不支持 async（会被改为同步执行并报「加载问题」），所以只给其它事件加 async。
install_codex() {
  [ -d "$HOME/.codex" ] || { say "codex: ~/.codex not found, skipped" "codex：未找到 ~/.codex，跳过"; return 0; }
  edit_json "$CODEX_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested_all($e;
          [{matcher: "", hooks: [{type: "command", command: ($hook + " codex " + $e)}
            + (if $e == "SessionEnd" or $e == "Interrupt" then {timeout: 3} else {async: true} end)]}]
          + (if $e == "PermissionRequest"
             then [{matcher: "", hooks: [{type: "command", command: ($approval + " codex"), timeout: 65}]}]
             elif $e == "PreToolUse"
             then [{matcher: "^request_user_input$", hooks: [{type: "command", command: ($approval + " codex"), timeout: 65}]}]
             else [] end)))' \
    --argjson events "$CODEX_EVENTS" --arg hook "$HOOK" --arg approval "$APPROVAL" && {
    n=$(count_ours "$CODEX_CFG")
    say "codex: $n pitwall hooks in $CODEX_CFG (trust the new approval and question hooks in Codex; user-reviewed requests and questions wait up to 60 seconds in Pitwall)" "codex：$CODEX_CFG 中 pitwall hook $n 个（需在 Codex 里信任新的审批与提问 hook；用户审批请求与提问在 Pitwall 中最多等待 60 秒）"
  }
}

install_cursor() {
  [ -d "$HOME/.cursor" ] || { say "cursor: ~/.cursor not found, skipped" "cursor：未找到 ~/.cursor，跳过"; return 0; }
  edit_json "$CURSOR_CFG" '
    (.version //= 1)
    | prune_flat($events)
    | reduce $events[] as $e (.; ensure_flat($e; {command: ($hook + " cursor " + $e), type: "command"}))' \
    --argjson events "$CURSOR_EVENTS" --arg hook "$HOOK" && {
    n=$(count_ours "$CURSOR_CFG")
    say "cursor: $n pitwall hooks in $CURSOR_CFG" "cursor：$CURSOR_CFG 中 pitwall hook $n 个"
  }
}

install_pi() {
  [ -d "$HOME/.pi/agent" ] || { say "pi: ~/.pi/agent not found, skipped" "pi：未找到 ~/.pi/agent，跳过"; return 0; }
  # 这个文件是 pitwall 自己的扩展，不是用户配置：直接覆盖，不备份。
  mkdir -p "$(dirname "$PI_EXT")" && install -m 644 "$here/pi/pitwall.ts" "$PI_EXT" || return 1
  say "pi: extension installed at $PI_EXT (new Pi sessions pick it up; run /reload in open ones; it can answer other extensions' allow / reject prompts from Pitwall)" "pi：扩展已放到 ${PI_EXT}（新开的 Pi 会话生效，已开的会话可 /reload；可在 Pitwall 中回答其它扩展的允许 / 拒绝提示）"
}

install_opencode() {
  # OpenCode 不要求用户配置目录存在；装了 opencode 命令或已有配置目录都算已安装。
  [ -d "$HOME/.config/opencode" ] || [ -x "$HOME/.opencode/bin/opencode" ] || command -v opencode >/dev/null 2>&1 ||
    { say "opencode: OpenCode not found, skipped" "opencode：未找到 OpenCode，跳过"; return 0; }
  mkdir -p "$OPENCODE_PLUGIN" &&
    install -m 644 "$here/opencode/pitwall/server.ts" "$here/opencode/pitwall/tui.ts" "$OPENCODE_PLUGIN/" &&
    rm -f "$OPENCODE_LEGACY_PLUGIN" || return 1
  say "opencode: plugin installed at $OPENCODE_PLUGIN (OpenCode watches the plugin directory and picks it up automatically; restart open OpenCode terminals so they can be selected from Pitwall)" "opencode：插件已安装到 ${OPENCODE_PLUGIN}（OpenCode 会监视插件目录并自动加载；重开已打开的 OpenCode 终端后，Pitwall 才能定位到它们）"
}

# Devin 的 hook 是同步执行的（没有 async）；pitwall-hook 只做一次 jq 追加，并设 10 秒上限。
# PermissionRequest 另登记 pitwall-approval：Devin 等它返回才显示自己的审批框，脚本最多等 60 秒。
# PreToolUse 另为 ask_user_question 登记 pitwall-approval（matcher 是正则），提问同样最多等 60 秒。
install_devin() {
  [ -d "$HOME/.config/devin" ] || { say "devin: ~/.config/devin not found, skipped" "devin：未找到 ~/.config/devin，跳过"; return 0; }
  edit_json "$DEVIN_CFG" '
    prune_nested($events)
    | reduce $events[] as $e (.;
        ensure_nested_all($e;
          [{hooks: [{type: "command", command: ($hook + " devin " + $e), timeout: 10}]}]
          + (if $e == "PermissionRequest"
             then [{hooks: [{type: "command", command: ($approval + " devin"), timeout: 65}]}]
             elif $e == "PreToolUse"
             then [{matcher: "^ask_user_question$", hooks: [{type: "command", command: ($approval + " devin"), timeout: 65}]}]
             else [] end)))' \
    --argjson events "$DEVIN_EVENTS" --arg hook "$HOOK" --arg approval "$APPROVAL" || return 1
  n=$(count_ours "$DEVIN_CFG")
  say "devin: $n pitwall hooks in $DEVIN_CFG (new Devin sessions pick them up; requests and questions wait up to 60 seconds in Pitwall)" "devin：$DEVIN_CFG 中 pitwall hook $n 个（新开的 Devin 会话生效；审批请求与提问在 Pitwall 中最多等待 60 秒）"
  # 用户自己登记在其它事件名下的 hook 不归我们删，但它会让 Devin 忽略全部 hooks（包括我们的）。
  extra=$("$JQ" -r --argjson events "$DEVIN_EVENTS" '(.hooks // {}) | keys - $events | join(", ")' "$DEVIN_CFG" 2>/dev/null) || extra=''
  [ -z "$extra" ] || say "  ✗ devin: hooks contain events Devin does not know ($extra), so Devin ignores all hooks; remove those events by hand" "  ✗ devin：hooks 含 Devin 不认识的事件（${extra}），Devin 会忽略全部 hooks；请手动移除这些事件"
}

uninstall_claude() {
  [ -e "$CLAUDE_CFG" ] || return 0
  edit_json "$CLAUDE_CFG" 'strip_nested | if .hooks == {} then del(.hooks) else . end' &&
    say "claude-code: pitwall hooks removed" "claude-code：已移除 pitwall hook"
}

uninstall_codex() {
  [ -e "$CODEX_CFG" ] || return 0
  edit_json "$CODEX_CFG" 'strip_nested | .hooks //= {}' && say "codex: pitwall hooks removed" "codex：已移除 pitwall hook"
}

uninstall_cursor() {
  [ -e "$CURSOR_CFG" ] || return 0
  edit_json "$CURSOR_CFG" 'strip_flat | .hooks //= {}' && say "cursor: pitwall hooks removed" "cursor：已移除 pitwall hook"
}

uninstall_devin() {
  [ -e "$DEVIN_CFG" ] || return 0
  edit_json "$DEVIN_CFG" 'strip_nested | if .hooks == {} then del(.hooks) else . end' &&
    say "devin: pitwall hooks removed" "devin：已移除 pitwall hook"
}

uninstall_pi() {
  [ -e "$PI_EXT" ] || return 0
  rm -f "$PI_EXT" && say "pi: extension removed" "pi：已移除扩展"
}

uninstall_opencode() {
  [ -e "$OPENCODE_PLUGIN" ] || [ -e "$OPENCODE_LEGACY_PLUGIN" ] || return 0
  # 只删 Pitwall 自己的文件；目录里若有别的文件，目录保留。
  rm -f "$OPENCODE_PLUGIN/server.ts" "$OPENCODE_PLUGIN/tui.ts" "$OPENCODE_LEGACY_PLUGIN" &&
    { [ ! -d "$OPENCODE_PLUGIN" ] || rmdir "$OPENCODE_PLUGIN" 2>/dev/null || true; } &&
    say "opencode: plugin removed" "opencode：已移除插件"
}

# 只清理本脚本建的 <日期>-<时间> 目录，按名字排序保留最新的 BACKUP_KEEP 份；其它文件不碰。
prune_backups() {
  dir="$PW_HOME/backups"
  [ -d "$dir" ] || return 0
  ls -1 "$dir" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort |
    awk -v keep="$BACKUP_KEEP" '{ name[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print name[i] }' |
    while read -r old; do rm -rf "${dir:?}/$old"; done
}

usage() {
  name=$(basename "$0")
  cat <<EOF
Install or remove Pitwall's event collection.
安装或卸载 Pitwall 的事件采集。

  $name install   [claude-code] [codex] [cursor] [pi] [devin] [opencode]   # no agents = all / 不带参数 = 全部
  $name uninstall [claude-code] [codex] [cursor] [pi] [devin] [opencode]

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

# 某个 agent 失败只跳过它自己：记下名字，其余照常进行，最后统一报告并以非零退出。
# 注意：在 || 左侧调用的函数里 set -e 不生效，所以每个 install_* / uninstall_* 都要自己返回失败状态。
failed=''
run_agent() { # <动作前缀> <agent>
  case $2 in
    claude-code) "$1"_claude ;;
    codex) "$1"_codex ;;
    cursor) "$1"_cursor ;;
    pi) "$1"_pi ;;
    devin) "$1"_devin ;;
    opencode) "$1"_opencode ;;
    *) say "unknown agent: $2" "未知 agent：$2" ;;
  esac || failed="$failed $2"
}

report_failed() {
  [ -n "$failed" ] || return 0
  list=$(printf '%s' "${failed# }" | sed 's/ /, /g')
  log ""
  say "✗ $1 did not finish for: $list (see the ✗ lines above); the other agents were handled" "✗ 以下 agent 未完成$2：${list}（原因见上方 ✗ 行）；其余 agent 已处理"
  exit 1
}

cmd=${1:-}
[ $# -gt 0 ] && shift
agents=${*:-claude-code codex cursor pi devin opencode}

[ -x "$JQ" ] || { say "needs /usr/bin/jq (part of macOS 15 and later)" "需要 /usr/bin/jq（macOS 15 起系统自带）"; exit 1; }

case "$cmd" in
  install)
    mkdir -p "$BIN_DIR" "$PW_HOME/events"
    install -m 755 "$here/bin/pitwall-hook" "$HOOK"
    install -m 755 "$here/bin/pitwall-events" "$BIN_DIR/pitwall-events"
    install -m 755 "$here/bin/pitwall-approval" "$APPROVAL"
    for a in $agents; do run_agent install "$a"; done
    prune_backups
    [ -d "$BACKUP_DIR" ] && say "original configs backed up to $BACKUP_DIR" "原配置已备份到 $BACKUP_DIR"
    log ""
    say "events go to $PW_HOME/events/<agent>.jsonl; inspect them with $BIN_DIR/pitwall-events status | summary | tail -f | doctor" "事件写入 $PW_HOME/events/<agent>.jsonl，查看：$BIN_DIR/pitwall-events status | summary | tail -f | doctor"
    case " $agents " in
      *" codex "*) say "Codex holds new hooks for review: open /hooks in Codex and trust the pitwall hooks (this script does not do it for you)." "Codex 会拦下新 hook 等你审核：在 Codex 里打开 /hooks 信任 pitwall 的 hook（本脚本不会代签）。" ;;
    esac
    report_failed install 安装
    ;;
  uninstall)
    for a in $agents; do run_agent uninstall "$a"; done
    prune_backups
    [ -d "$BACKUP_DIR" ] && say "configs before the change backed up to $BACKUP_DIR" "改动前的配置已备份到 $BACKUP_DIR"
    say "collected events stay in $PW_HOME/events/; delete them yourself if you want." "已采集的事件保留在 $PW_HOME/events/，需要时手动删除。"
    report_failed uninstall 卸载
    ;;
  *)
    usage
    exit 2
    ;;
esac
