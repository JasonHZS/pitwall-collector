#!/bin/sh
# 提问：Claude Code 的回答作为 updatedInput；Codex / Devin 的回答写进阻止原因交给模型；无效回答交回原生提问。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-question-approval.XXXXXX")
export PITWALL_HOME="$tmp/pitwall"
APPROVAL="$root/bin/pitwall-approval"
JQ=/usr/bin/jq
APPR="$PITWALL_HOME/approvals"
jobs=''
cleanup() {
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
mkdir -p "$APPR/requests" "$APPR/decisions"

# 两道题：多选 + 单选；额外字段 metadata 必须原样回传。
"$JQ" -n '{session_id: "question-test", hook_event_name: "PermissionRequest", tool_name: "AskUserQuestion",
  tool_use_id: "question-call", tool_input: {metadata: {keep: true}, questions: [
    {question: "选择哪里？", header: "位置", multiSelect: true,
     options: [{label: "Agent", description: ("长描述" * 2000)}, {label: "状态栏"}]},
    {question: "其他要求？", header: "要求", multiSelect: false, options: [{label: "无"}, {label: "稍后"}]}]}}' > "$tmp/payload.json"
# 超过 1 MiB 的输入：作为命令行参数会超出 ARG_MAX。
"$JQ" '.tool_input.questions[0].options[0].description = ("x" * 1200000)' "$tmp/payload.json" > "$tmp/large.json"

request_file() {
  i=0
  while [ "$i" -lt 50 ]; do
    set -- "$APPR"/requests/*question-test.*.json
    if [ -e "$1" ]; then printf '%s' "$1"; return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
# ask <payload> <name> <reply> [agent]: runs the hook, answers with <reply> once the request appears.
ask() {
  touch "$APPR/listening"
  sh "$APPROVAL" "${4:-claude-code}" < "$1" > "$tmp/$2.out" &
  started=$!; jobs="$jobs $started"
  file=$(request_file) || { kill "$started" 2>/dev/null; return 1; }
  cp "$file" "$tmp/$2.request"
  printf '%s' "$3" > "$tmp/reply.tmp"
  mv "$tmp/reply.tmp" "$APPR/decisions/$("$JQ" -r .id "$file")"
  wait "$started"
}
spool_empty() { test -z "$(ls "$APPR"/requests/*.json "$APPR"/decisions/* 2>/dev/null)"; }

answers='{"answers":{"选择哪里？":"Agent, 状态栏","其他要求？":"自定义\"回答\n第二行"}}'
ask "$tmp/payload.json" full "$answers"
check "问题请求带回答格式标记、完整保留输入" "$JQ" -e --slurpfile p "$tmp/payload.json" \
  '.answer_format == "answers-v1" and .tool_input == $p[0].tool_input' "$tmp/full.request"
check "回答作为 updatedInput 返回，原输入不丢" "$JQ" -e --slurpfile p "$tmp/payload.json" --argjson a "$answers" \
  '.hookSpecificOutput == {hookEventName: "PermissionRequest",
     decision: {behavior: "allow", updatedInput: ($p[0].tool_input + {answers: $a.answers})}}' "$tmp/full.out"
check "回答后请求与决定文件都被清理" spool_empty

ask "$tmp/large.json" large "$answers"
check "超过 1 MiB 的问题输入照常返回回答" "$JQ" -e '.hookSpecificOutput.decision.updatedInput.answers["选择哪里？"] == "Agent, 状态栏"' "$tmp/large.out"

n=0
for reply in allow deny '{}' '{"answers":{"选择哪里？":"Agent"}}' '{"answers":{"选择哪里？":" ","其他要求？":"无"}}'; do
  n=$((n + 1))
  ask "$tmp/payload.json" "bad$n" "$reply"
  check "无效回答（$reply）不批准问题、无输出" test ! -s "$tmp/bad$n.out"
done
check "无效回答后同样清理" spool_empty

# 在 Claude Code 原生提问框里先回答：PermissionRequest 没有调用 ID，PostToolUse 的输入多出
# answers / annotations，仍要撤回这条请求；别的问题的完成事件不撤回。
"$JQ" 'del(.tool_use_id) | .session_id = "native-question-test"' "$tmp/payload.json" > "$tmp/native.json"
touch "$APPR/listening"
sh "$APPROVAL" claude-code < "$tmp/native.json" > "$tmp/native.out" &
started=$!; jobs="$jobs $started"
i=0
until set -- "$APPR"/requests/native-question-test.*.json; [ -e "$1" ] || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
native_request=$1
"$JQ" '.hook_event_name = "PostToolUse" | .tool_use_id = "toolu_other" | .tool_input.questions[1].question = "别的问题？"
  | .tool_input.answers = {"选择哪里？": "Agent", "别的问题？": "无"}' "$tmp/native.json" |
  sh "$root/bin/pitwall-hook" claude-code PostToolUse
check "别的问题的完成事件不撤回提问请求" test -e "$native_request"
"$JQ" '.hook_event_name = "PostToolUse" | .tool_use_id = "toolu_native"
  | .tool_input.answers = {"选择哪里？": "Agent", "其他要求？": "无"}
  | .tool_input.annotations = {"选择哪里？": {preview: "x"}}' "$tmp/native.json" |
  sh "$root/bin/pitwall-hook" claude-code PostToolUse
i=0
while [ -e "$native_request" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "原生提问框回答后撤回请求" test ! -e "$native_request"
# 没撤回时让监听过期，审批脚本自行退出，测试不会卡住。
touch -t "$(date -v-1M +%Y%m%d%H%M.%S)" "$APPR/listening"
wait "$started"
check "撤回后审批脚本无输出退出" sh -c 'test ! -e "$1" && test ! -s "$2"' sh "$native_request" "$tmp/native.out"
check "原生回答撤回后清理" spool_empty

# Codex request_user_input / Devin ask_user_question：PreToolUse 阻止调用，回答写进原因。
two='{"answers":{"选择哪里？":"Agent, 状态栏","其他要求？":"无"}}'
"$JQ" '.hook_event_name = "PreToolUse" | .tool_name = "request_user_input" | .turn_id = "t-1"
  | .tool_input.questions |= map(del(.multiSelect) + {id: .header})' "$tmp/payload.json" > "$tmp/codex.json"
ask "$tmp/codex.json" codex "$two" codex
check "Codex 提问请求带回答格式、完整保留输入" "$JQ" -e --slurpfile p "$tmp/codex.json" \
  '.agent == "codex" and .answer_format == "answers-v1" and .tool_name == "request_user_input" and .tool_input == $p[0].tool_input' "$tmp/codex.request"
check "Codex 回答作为 PreToolUse deny 原因交给模型" "$JQ" -e --argjson a "$two" '
  .hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"
  and (.hookSpecificOutput.permissionDecisionReason | split("\n")[1:] | join("\n") | fromjson) == $a.answers' "$tmp/codex.out"
"$JQ" '.hook_event_name = "PreToolUse" | .tool_name = "ask_user_question" | .prompt_id = "p-1"
  | .tool_input.questions |= map(del(.multiSelect) + {multi_select: true})' "$tmp/payload.json" > "$tmp/devin.json"
ask "$tmp/devin.json" devin "$two" devin
check "Devin 提问请求带回答格式、完整保留输入" "$JQ" -e --slurpfile p "$tmp/devin.json" \
  '.agent == "devin" and .answer_format == "answers-v1" and .turn_id == "p-1" and .tool_input == $p[0].tool_input' "$tmp/devin.request"
check "Devin 回答作为 block 原因交给模型" "$JQ" -e --argjson a "$two" '
  .decision == "block" and (.reason | split("\n")[1:] | join("\n") | fromjson) == $a.answers' "$tmp/devin.out"
ask "$tmp/devin.json" devin-bad allow devin
check "Devin 旧的 allow 不放行提问、无输出" test ! -s "$tmp/devin-bad.out"
check "Codex / Devin 提问处理后清理" spool_empty

# 其它工具的 PreToolUse（matcher 失效时）立即放行：不写请求、不输出。
for agent in codex devin; do
  touch "$APPR/listening"
  out=$("$JQ" -c '.hook_event_name = "PreToolUse" | .tool_name = "exec" | .tool_input = {command: "ls"}' "$tmp/payload.json" |
    sh "$APPROVAL" "$agent")
  check "$agent 其它工具的 PreToolUse 立即放行" sh -c 'test -z "$1" && test -z "$(ls "$2"/requests/*.json 2>/dev/null)"' sh "$out" "$APPR"
done

# 提问工具的 PermissionRequest 在 Pitwall 里既不能回答也不能批准：立即交回原生界面。
for pair in codex:request_user_input devin:ask_user_question; do
  agent=${pair%%:*}
  touch "$APPR/listening"
  out=$("$JQ" -c --arg tool "${pair#*:}" '.hook_event_name = "PermissionRequest" | .tool_name = $tool | .turn_id = "t-1" | .prompt_id = "p-1"' \
    "$tmp/payload.json" | sh "$APPROVAL" "$agent")
  check "$agent 提问工具的 PermissionRequest 立即交回" sh -c 'test -z "$1" && test -z "$(ls "$2"/requests/*.json 2>/dev/null)"' sh "$out" "$APPR"
done

[ "$fails" -eq 0 ] || { echo "question-approval: $fails 项失败"; exit 1; }
