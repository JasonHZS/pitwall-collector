#!/bin/sh
# Codex approval protocol and lifecycle, isolated from real agent configs and logs.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-codex-approval.XXXXXX")
export PITWALL_HOME="$tmp/pitwall"
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
rollout="$tmp/rollout.jsonl"
printf '%s\n' '{"type":"turn_context","payload":{"turn_id":"turn-1","approvals_reviewer":"user"}}' > "$rollout"
req=$("$JQ" -nc --arg transcript "$rollout" '{session_id:"sess", turn_id:"turn-1", transcript_path:$transcript,
  cwd:"/tmp/project", hook_event_name:"PermissionRequest", tool_name:"Bash", tool_input:{command:"touch x"}}')
await_count() {
  expected=$1; i=0
  while [ "$i" -lt 50 ]; do
    set -- "$APPR"/requests/codex.sess.*.json
    if [ -e "$1" ] && [ "$#" -eq "$expected" ]; then return 0; fi
    if [ ! -e "$1" ] && [ "$expected" -eq 0 ]; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
start() {
  touch "$APPR/listening"
  printf '%s' "$1" | sh "$APPROVAL" codex > "$tmp/$2.out" &
  started=$!; jobs="$jobs $started"
}
find_request() { "$JQ" -r "$1 | input_filename" "$APPR"/requests/codex.sess.*.json; }
answer() {
  id=$("$JQ" -r '.id' "$1")
  printf '%s' "$2" > "$APPR/decisions/$id"
}

start "$req" allow
check "Codex 用户审批写入待批文件" await_count 1
file=$(find_request 'select(.agent == "codex")')
jqcheck "Codex 请求保留会话、轮次、工具输入" "$file" '.agent == "codex" and .session_id == "sess" and .turn_id == "turn-1" and .tool_input.command == "touch x"'
answer "$file" allow; wait "$started"
jqcheck "Codex 批准返回官方 allow 格式" "$tmp/allow.out" '.hookSpecificOutput == {hookEventName:"PermissionRequest", decision:{behavior:"allow"}}'
check "Codex 回答后清理请求和决定" sh -c 'test ! -e "$1" && test ! -e "$2"' sh "$file" "$APPR/decisions/$id"
start "$req" deny
check "Codex 拒绝前请求存在" await_count 1
answer "$(find_request 'select(.agent == "codex")')" deny; wait "$started"
jqcheck "Codex 拒绝返回 deny 和原因" "$tmp/deny.out" '.hookSpecificOutput.decision.behavior == "deny" and (.hookSpecificOutput.decision.message | length) > 0'

# Auto-review, missing metadata and a different turn never pause the agent.
for reviewer in auto_review guardian_subagent unknown; do
  "$JQ" -nc --arg reviewer "$reviewer" '{type:"turn_context",payload:{turn_id:"turn-1",approvals_reviewer:$reviewer}}' > "$rollout"
  printf '%s' "$req" | sh "$APPROVAL" codex > "$tmp/skip.out"
  check "Codex $reviewer 无输出、不创建请求" sh -c 'test ! -s "$1" && test -z "$(ls "$2"/*.json 2>/dev/null)"' sh "$tmp/skip.out" "$APPR/requests"
done
printf '%s\n' '{"type":"turn_context","payload":{"turn_id":"other-turn","approvals_reviewer":"user"}}' > "$rollout"
printf '%s' "$req" | sh "$APPROVAL" codex > "$tmp/skip.out"
check "其它轮次的 user metadata 不接管当前审批" test ! -s "$tmp/skip.out"
printf '%s\n' '{"type":"turn_context","payload":{"turn_id":"turn-1","approvals_reviewer":"user"}}' > "$rollout"

# Same session ID in Claude Code is independent; stale lifecycle events cannot withdraw a new turn.
printf '%s\n' '{"v":1,"id":"claude-other","agent":"claude-code","session_id":"sess","tool_name":"Bash","created_at":0}' > "$APPR/requests/sess.Bash.claude-other.json"
start "$req" interrupt
check "Codex 中断测试的请求存在" await_count 1
printf '%s' '{"session_id":"sess","turn_id":"old-turn"}' | sh "$HOOK" codex Stop
check "旧轮 Stop 不撤回当前轮请求" await_count 1
printf '%s' '{"session_id":"sess","turn_id":"old-turn"}' | sh "$HOOK" codex UserPromptSubmit
check "旧轮 UserPromptSubmit 迟到不撤回新轮请求" await_count 1
printf '%s' '{"session_id":"sess","turn_id":"turn-1"}' | sh "$HOOK" codex UserPromptSubmit
check "当前轮异步 UserPromptSubmit 不撤回当前请求" await_count 1
printf '%s' '{"session_id":"sess","turn_id":"new-turn"}' | sh "$HOOK" codex UserPromptSubmit
check "不同轮 UserPromptSubmit 不按 ID 猜测请求先后" await_count 1
printf '%s' '{"session_id":"sess","turn_id":"turn-1"}' | sh "$HOOK" codex Interrupt
wait "$started"
check "中断后无决定交回 Codex" test ! -s "$tmp/interrupt.out"
check "同轮 Interrupt 撤回保留的请求" await_count 0
check "Codex 撤回不删除 Claude 的同名会话" test -f "$APPR/requests/sess.Bash.claude-other.json"

# Two identical calls with IDs: completion removes only the answered call.
first=$(printf '%s' "$req" | "$JQ" -c '.tool_use_id="call-1"')
second=$(printf '%s' "$req" | "$JQ" -c '.tool_use_id="call-2"')
start "$first" first; first_pid=$started
start "$second" second; second_pid=$started
check "Codex 同名同输入的两个请求同时存在" await_count 2
second_file=$(find_request 'select(.tool_use_id == "call-2")')
printf '%s' "$first" | sh "$HOOK" codex PostToolUse
wait "$first_pid"
check "Codex 完成只撤回对应调用" test -f "$second_file"
answer "$second_file" allow; wait "$second_pid"
jqcheck "另一条 Codex 请求仍能批准" "$tmp/second.out" '.hookSpecificOutput.decision.behavior == "allow"'
start "$req" disabled
check "Codex 关闭监听前请求存在" await_count 1
rm "$APPR/listening"; wait "$started"
check "Codex 关闭监听立即无输出清理" sh -c 'test ! -s "$1" && test -z "$(ls "$2"/codex.*.json 2>/dev/null)"' sh "$tmp/disabled.out" "$APPR/requests"
touch "$APPR/listening"
printf '%s' "$req" | sh "$APPROVAL" cursor > "$tmp/foreign.out"
check "不支持的 Agent 无输出退出" test ! -s "$tmp/foreign.out"
printf 'Codex 审批检查：%s 项失败\n' "$fails"
[ "$fails" -eq 0 ]
