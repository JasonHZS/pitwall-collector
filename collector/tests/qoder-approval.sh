#!/bin/sh
# Qoder CN hook 协议的隔离测试；不调用模型或修改真实配置。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-qoder-approval.XXXXXX")
export PITWALL_HOME="$tmp/pitwall"
JQ=/usr/bin/jq
APPR="$PITWALL_HOME/approvals"
jobs=''
cleanup() {
  for pid in $jobs; do kill -CONT "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$APPR/requests" "$APPR/decisions"
printf '%s' '{"session_id":"q1","hook_event_name":"PermissionRequest","cwd":"/repo","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"printf QODER_OK"}}' > "$tmp/command.json"
"$JQ" '.hook_event_name = "PreToolUse" | .tool_name = "AskUserQuestion" | .tool_use_id = "ask1"
  | .tool_input = {metadata:{keep:true}, questions:[
      {question:"哪些颜色？",header:"颜色",multiSelect:true,options:[{label:"红",description:"红色"},{label:"蓝"}]},
      {question:"其他要求？",header:"要求",options:[{label:"无"},{label:"有"}]}]}' "$tmp/command.json" > "$tmp/question.json"

start() {
  name=$2
  touch "$APPR/listening"
  sh "$root/bin/pitwall-approval" qoder-cn < "$1" > "$tmp/$2.out" &
  started=$!; jobs="$jobs $started"
  i=0
  while [ "$i" -lt 50 ]; do
    set -- "$APPR"/requests/qoder-cn.q1.*.json
    if [ -e "$1" ]; then
      file=$1
      id=$("$JQ" -r .id "$file")
      cp "$file" "$tmp/$name.request"
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  echo 'Qoder request did not appear' >&2; return 1
}
reply() {
  printf '%s' "$1" > "$tmp/decision"
  mv "$tmp/decision" "$APPR/decisions/$id"
  wait "$started"
  test ! -e "$file" && test ! -e "$APPR/decisions/$id"
}
observe() { sh "$root/bin/pitwall-hook" qoder-cn "$1"; }
immediate() {
  # 即使误接管也只等到心跳过期；随后断言没有请求也没有输出。
  touch "$APPR/listening"
  sh "$root/bin/pitwall-approval" qoder-cn < "$1" > "$tmp/immediate.out"
  test ! -s "$tmp/immediate.out"
  set -- "$APPR"/requests/*.json
  test ! -e "$1"
}

for decision in allow deny; do
  start "$tmp/command.json" "$decision"
  "$JQ" -e '.agent == "qoder-cn" and .cwd == "/repo" and .answer_format == null and .tool_input.command == "printf QODER_OK"' "$file" >/dev/null
  reply "$decision"
  "$JQ" -e --arg d "$decision" '.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == $d' "$tmp/$decision.out" >/dev/null
done
start "$tmp/command.json" invalid
reply '{}'
test ! -s "$tmp/invalid.out"

start "$tmp/question.json" question
"$JQ" -e --slurpfile p "$tmp/question.json" '.answer_format == "answers-v1" and .tool_use_id == "ask1" and .tool_input == $p[0].tool_input' "$file" >/dev/null
answers='{"answers":{"哪些颜色？":"红, 蓝","其他要求？":"自定义\"回答\n第二行"}}'
reply "$answers"
"$JQ" -e --argjson a "$answers" '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"
  and (.hookSpecificOutput.permissionDecisionReason | split("\n")[1:] | join("\n") | fromjson) == $a.answers' "$tmp/question.out" >/dev/null
for bad in allow deny '{"answers":{"哪些颜色？":"红"}}' '{"answers":{"哪些颜色？":"红","其他要求？":" "}}' '{"answers":{"哪些颜色？":"红","其他要求？":"无","多余":"x"}}'; do
  start "$tmp/question.json" bad
  reply "$bad"
  test ! -s "$tmp/bad.out"
done

# 不属于这次接管的事件 / 子 Agent / 未知问题格式立即退出。
"$JQ" '.hook_event_name = "PreToolUse"' "$tmp/command.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.hook_event_name = "PermissionRequest"' "$tmp/question.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.agent_id = "child"' "$tmp/question.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.agent_id = "child"' "$tmp/command.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.hook_event_name = "Stop"' "$tmp/command.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.tool_input.questions[0].options = "bad"' "$tmp/question.json" > "$tmp/other.json"; immediate "$tmp/other.json"
"$JQ" '.tool_input.questions[0].options[0].label = "蓝"' "$tmp/question.json" > "$tmp/other.json"; immediate "$tmp/other.json"

# 并行其它工具、子 Agent 和可阻止的 Stop 不撤回主 Agent 的请求。
start "$tmp/question.json" withdraw
"$JQ" '.tool_use_id = "other"' "$tmp/question.json" | observe PostToolUse
test -e "$file"
"$JQ" '.agent_id = "child"' "$tmp/question.json" | observe PostToolUse
test -e "$file"
printf '%s' '{"session_id":"q1","agent_id":"child","request_set_id":"r1","reason":"end_turn"}' | observe QueryEnd
test -e "$file"
printf '%s' '{"session_id":"q1","parent_request_set_id":"r1"}' | observe Stop
test -e "$file"
"$JQ" '.tool_input.answers = {"哪些颜色？":"红","其他要求？":"无"}' "$tmp/question.json" | observe PostToolUse
wait "$started"
test ! -e "$file" && test ! -s "$tmp/withdraw.out"

# 真实 PermissionRequest 不带调用 ID / 轮次 ID；唯一输入指纹仍能撤回。
"$JQ" '.session_id = "q1" | .tool_input.command = "printf UNIQUE"' "$tmp/command.json" > "$tmp/unique.json"
start "$tmp/unique.json" fingerprint
cat "$tmp/unique.json" | observe PermissionDenied
wait "$started"
test ! -e "$file" && test ! -s "$tmp/fingerprint.out"
for event in QueryEnd UserPromptSubmit SessionEnd; do
  start "$tmp/question.json" "$event"
  printf '%s' '{"session_id":"q1","request_set_id":"r1","reason":"abort"}' | observe "$event"
  wait "$started"
  test ! -e "$file" && test ! -s "$tmp/$event.out"
done
test -z "$(find "$APPR/requests" -name '*.seen' -print)"

# 心跳失效时，即使磁盘已出现 allow 也不能批准；请求与决定均清理。
start "$tmp/command.json" stale
kill -STOP "$started"
touch -t "$(date -v-1M +%Y%m%d%H%M.%S)" "$APPR/listening"
printf allow > "$APPR/decisions/$id"
kill -CONT "$started"
wait "$started"
test ! -e "$file" && test ! -e "$APPR/decisions/$id" && test ! -s "$tmp/stale.out"
sh "$root/bin/pitwall-approval" qoder-cn < "$tmp/command.json" > "$tmp/offline.out"
test ! -s "$tmp/offline.out"

# 心跳持续更新时仍须在 60 秒附近回退，而不是继承 Claude 的 900 秒。
start "$tmp/question.json" timeout
timeout_started=$(date +%s)
(
  # 有界更新，脚本失去超时保护时测试也会在心跳过期后退出、明确失败。
  n=0
  while [ "$n" -lt 32 ] && kill -0 "$started" 2>/dev/null; do
    touch "$APPR/listening"; sleep 2; n=$((n + 1))
  done
) &
heartbeat=$!; jobs="$jobs $heartbeat"
wait "$started"
elapsed=$(($(date +%s) - timeout_started))
kill "$heartbeat" 2>/dev/null || true
wait "$heartbeat" 2>/dev/null || true
test "$elapsed" -ge 58 && test "$elapsed" -le 63
test ! -e "$file" && test ! -s "$tmp/timeout.out"
echo 'Qoder CN：命令批准 / 拒绝、问题回答、原生回退、撤回与心跳清理通过'
