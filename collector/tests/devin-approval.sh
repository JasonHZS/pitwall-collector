#!/bin/sh
# Devin approval protocol and lifecycle, isolated from real agent configs and logs.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-devin-approval.XXXXXX")
export PITWALL_HOME="$tmp/pitwall"
export DEVIN_PROJECT_DIR=/tmp/devin-project
APPROVAL="$root/bin/pitwall-approval"
HOOK="$root/bin/pitwall-hook"
JQ=/usr/bin/jq
APPR="$PITWALL_HOME/approvals"
jobs=''
cleanup() {
  rm -f "$APPR/listening"
  for pid in $jobs; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
check() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$desc"
  else printf '  FAIL %s\n' "$desc"; fails=$((fails + 1)); fi
}
jqcheck() { check "$1" "$JQ" -e "$3" "$2"; }
mkdir -p "$APPR/requests" "$APPR/decisions"
touch "$APPR/listening"
# Devin 的真实 payload：没有 cwd / turn_id / transcript_path，轮次是 prompt_id。
req='{"hook_event_name":"PermissionRequest","tool_name":"exec","tool_input":{"command":"touch x"},"tool_use_id":"exec:0#1","session_id":"peat-hair","prompt_id":"p-1"}'
await_count() {
  expected=$1; i=0
  while [ "$i" -lt 50 ]; do
    set -- "$APPR"/requests/devin.peat-hair.*.json
    if [ -e "$1" ] && [ "$#" -eq "$expected" ]; then return 0; fi
    if [ ! -e "$1" ] && [ "$expected" -eq 0 ]; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
start() {
  touch "$APPR/listening"
  printf '%s' "$1" | sh "$APPROVAL" devin > "$tmp/$2.out" &
  started=$!; jobs="$jobs $started"
}
request_file() { set -- "$APPR"/requests/devin.peat-hair.*.json; printf '%s' "$1"; }
answer() { printf '%s' "$2" > "$APPR/decisions/$("$JQ" -r '.id' "$1")"; }

start "$req" allow
check "Devin 审批写入待批文件" await_count 1
file=$(request_file)
jqcheck "Devin 请求用 DEVIN_PROJECT_DIR 作 cwd、prompt_id 作轮次" "$file" '.agent == "devin" and .session_id == "peat-hair" and .turn_id == "p-1" and .cwd == "/tmp/devin-project" and .tool_name == "exec" and .tool_input.command == "touch x" and .tool_use_id == "exec:0#1"'
answer "$file" allow; wait "$started"
# Devin 3000.11.3 实测接受与 Claude Code 相同的 hookSpecificOutput 格式（批准与拒绝都生效）。
jqcheck "Devin 批准返回 allow" "$tmp/allow.out" '.hookSpecificOutput == {hookEventName:"PermissionRequest", decision:{behavior:"allow"}}'
start "$req" deny
check "Devin 拒绝前请求存在" await_count 1
answer "$(request_file)" deny; wait "$started"
jqcheck "Devin 拒绝返回 deny 和原因" "$tmp/deny.out" '.hookSpecificOutput.decision.behavior == "deny" and (.hookSpecificOutput.decision.message | length) > 0'

# 打印模式没有人能回答：不接管，立即交回 Devin。
for flag in -p --print --print=probe -pprobe; do
  touch "$APPR/listening"
  rm -f "$tmp/print.done"
  sh -c 'printf "%s" "$1" | sh "$2" devin > "$3"; : > "$4"' "$flag" "$req" "$APPROVAL" "$tmp/print.out" "$tmp/print.done" &
  started=$!; jobs="$jobs $started"
  i=0
  while [ ! -e "$tmp/print.done" ] && [ "$i" -lt 10 ]; do sleep 0.1; i=$((i + 1)); done
  check "Devin 打印模式（${flag}）立即无输出、不创建请求" sh -c 'test -e "$1" && test ! -s "$2" && test -z "$(ls "$3"/*.json 2>/dev/null)"' sh "$tmp/print.done" "$tmp/print.out" "$APPR/requests"
  # 失败也及时撤回，不能靠心跳过期或 60 秒超时让测试假通过。
  rm -f "$APPR/listening"; wait "$started"
done

# -- 之后是交互会话的 prompt，里面的 -p / --print= 不是打印模式选项。
touch "$APPR/listening"
sh -c 'printf "%s" "$1" | sh "$2" devin > "$3"; :' -- "$req" "$APPROVAL" "$tmp/prompt.out" 'explain -p --print=probe' &
started=$!; jobs="$jobs $started"
check "Devin prompt 中的打印参数不跳过审批" await_count 1
answer "$(request_file)" allow; wait "$started"
jqcheck "Devin 含打印参数的交互 prompt 仍可批准" "$tmp/prompt.out" '.hookSpecificOutput.decision.behavior == "allow"'

# Claude Code 的同名会话互不影响；旧轮 Stop 不撤回当前轮。
printf '%s\n' '{"v":1,"id":"claude-other","agent":"claude-code","session_id":"peat-hair","tool_name":"Bash","created_at":0}' > "$APPR/requests/peat-hair.Bash.claude-other.json"
start "$req" stop
check "Devin Stop 测试的请求存在" await_count 1
printf '%s' '{"session_id":"peat-hair","prompt_id":"p-0"}' | sh "$HOOK" devin Stop
check "旧轮 Stop 不撤回当前轮请求" await_count 1
printf '%s' '{"session_id":"peat-hair","prompt_id":"p-1"}' | sh "$HOOK" devin Stop
wait "$started"
check "同轮 Stop 撤回请求，无决定交回 Devin" sh -c 'test ! -s "$1"' sh "$tmp/stop.out"
check "Devin 撤回不删除 Claude 的同名会话" test -f "$APPR/requests/peat-hair.Bash.claude-other.json"
start "$req" end
check "Devin SessionEnd 测试的请求存在" await_count 1
printf '%s' '{"session_id":"peat-hair","prompt_id":"p-1","reason":"other"}' | sh "$HOOK" devin SessionEnd
wait "$started"
check "SessionEnd 撤回会话的请求与指纹标记" sh -c 'test ! -s "$1" && test -z "$(ls -d "$2"/devin.peat-hair.*.seen 2>/dev/null)"' sh "$tmp/end.out" "$APPR/requests"
start "$req" disabled
check "Devin 关闭监听前请求存在" await_count 1
rm "$APPR/listening"; wait "$started"
check "Devin 关闭监听立即无输出清理" sh -c 'test ! -s "$1" && test -z "$(ls "$2"/devin.*.json 2>/dev/null)"' sh "$tmp/disabled.out" "$APPR/requests"
printf 'Devin 审批检查：%s 项失败\n' "$fails"
[ "$fails" -eq 0 ]
