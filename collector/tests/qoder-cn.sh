#!/bin/sh
# 隔离 HOME 验证 Qoder CN 配置与脱敏，不调用真实 Agent。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
qoder_test_home=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-qoder-test.XXXXXX")
trap 'rm -rf "$qoder_test_home"' EXIT
export HOME="$qoder_test_home" PITWALL_HOME="$qoder_test_home/.pitwall"
mkdir -p "$HOME/.qoder-cn"
cfg="$HOME/.qoder-cn/settings.json"
printf '%s\n' '{"model":"keep-me","hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-hook"}]}]}}' > "$cfg"
sh "$root/install.sh" install qoder-cn >/dev/null
/usr/bin/jq -e '[.. | objects | select((.command // "") | contains("pitwall-hook"))] | length == 12' "$cfg" >/dev/null
/usr/bin/jq -e '.model == "keep-me" and any(.hooks.Stop[].hooks[]; .command == "user-hook")
  and ([.. | objects | select((.command // "") | contains("pitwall-approval"))] | length == 2)
  and any(.hooks.PermissionRequest[].hooks[]; (.command | endswith("pitwall-approval qoder-cn")) and .timeout == 65 and .async == null)
  and any(.hooks.PreToolUse[]; .matcher == "^AskUserQuestion$" and any(.hooks[]; (.command | endswith("pitwall-approval qoder-cn")) and .timeout == 65))' "$cfg" >/dev/null
before=$(shasum "$cfg")
sh "$root/install.sh" install qoder-cn >/dev/null
[ "$before" = "$(shasum "$cfg")" ]
[ -f "$(find "$PITWALL_HOME/backups" -name qoder-cn_settings.json -print | head -1)" ]
hook="$PITWALL_HOME/bin/pitwall-hook"
printf '%s' '{"session_id":"q1","request_set_id":"r1","prompt":"摘要\nSECRET-PROMPT"}' | "$hook" qoder-cn UserPromptSubmit
printf '%s' '{"session_id":"q1","parent_request_set_id":"r1","last_assistant_message":"回复\n完成"}' | "$hook" qoder-cn Stop
printf '%s' '{"session_id":"q1","notification_type":"permission_prompt","details":{"toolName":"AskUserQuestion","toolUseId":"call_1","input":{"questions":[{"question":"请选择\nSECRET-QUESTION","options":[{"label":"SECRET-OPTION"}]}]},"message":"SECRET-MESSAGE"}}' | "$hook" qoder-cn Notification
printf '%s' '{"session_id":"q1","tool_name":"AskUserQuestion","tool_use_id":"call_1","tool_input":{"answers":"SECRET-ANSWER"}}' | "$hook" qoder-cn PostToolUse
printf '%s' '{"session_id":"q1","request_set_id":"r1","reason":"end_turn"}' | "$hook" qoder-cn QueryEnd
spool="$PITWALL_HOME/events/qoder-cn.jsonl"
/usr/bin/jq -se '.[0].prompt_id == "r1" and .[0].prompt_head == "摘要" and .[1].prompt_id == "r1" and .[1].reply_head == "回复 完成" and .[2].tool_name == "AskUserQuestion" and .[2].tool_use_id == "call_1" and .[2].tool_summary == "请选择" and .[3].tool_use_id == "call_1" and .[4].reason == "end_turn"' "$spool" >/dev/null
! grep -q SECRET "$spool"
"$PITWALL_HOME/bin/pitwall-events" status --json | /usr/bin/jq -e '.state == "done"' >/dev/null
printf '%s' '{"session_id":"q1","tool_name":"Read","tool_use_id":"late"}' | "$hook" qoder-cn PostToolUse
"$PITWALL_HOME/bin/pitwall-events" status --json | /usr/bin/jq -e '.state == "done"' >/dev/null
# 提问回答借阻止原因返回模型；Qoder 的失败 / 拒绝事件即使重带答案也不能持久保存。
for event in PostToolUseFailure PermissionDenied; do
  printf '%s' '{"session_id":"q1","tool_name":"AskUserQuestion","tool_use_id":"answered","error":"SECRET-ANSWER","reason":"SECRET-ANSWER","message":"SECRET-ANSWER"}' | "$hook" qoder-cn "$event"
done
/usr/bin/jq -se '.[-2:] | all(.tool_use_id == "answered" and .tool_name == "AskUserQuestion" and .error == null and .reason == null and .message == null)' "$spool" >/dev/null
! grep -q SECRET "$spool"
sh "$root/install.sh" uninstall qoder-cn >/dev/null
/usr/bin/jq -e '.model == "keep-me" and [.hooks.Stop[].hooks[].command] == ["user-hook"] and ([.. | objects | select((.command // "") | test("pitwall-hook|pitwall-approval"))] | length == 0)' "$cfg" >/dev/null
printf '{ broken' > "$cfg"
if sh "$root/install.sh" install qoder-cn >/dev/null 2>&1; then exit 1; fi
[ "$(cat "$cfg")" = '{ broken' ]
echo 'Qoder CN：安装 / 幂等 / 备份 / 卸载 / 脱敏通过'
