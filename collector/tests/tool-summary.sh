#!/bin/sh
# Tool inputs may use "questions" for unrelated data. Never lose the event while summarizing it.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-tool-summary.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" PITWALL_HOME="$tmp/pitwall"
JQ=/usr/bin/jq
for agent in claude-code qoder-cn zcode; do
  file="$PITWALL_HOME/events/$agent.jsonl"
  for tool in Custom AskUserQuestion; do
    for shape in 'null' '"hello"' 'false' '42' '{}' '[42]' '["hello"]'; do
      printf '%s' '{"session_id":"summary-session","tool_use_id":"call-a"}' |
        "$JQ" --arg tool "$tool" --argjson shape "$shape" '.tool_name=$tool | .tool_input={questions:$shape}' |
        sh "$root/bin/pitwall-hook" "$agent" PermissionRequest
      tail -n 1 "$file" | "$JQ" -e --arg tool "$tool" '
        .session_id=="summary-session" and .event=="PermissionRequest" and .tool_name==$tool
        and (has("parse_error") | not) and (has("tool_summary") | not)' >/dev/null
    done
  done
  printf '%s' '{"session_id":"summary-session","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?\nextra"}]}}' |
    sh "$root/bin/pitwall-hook" "$agent" PermissionRequest
  tail -n 1 "$file" | "$JQ" -e '.tool_summary=="Which one?" and .session_id=="summary-session"' >/dev/null
  printf '%s' '{"session_id":"summary-session","tool_name":"Custom","tool_input":{"questions":[{"question":"UNRELATED_DATA"}]}}' |
    sh "$root/bin/pitwall-hook" "$agent" PermissionRequest
  tail -n 1 "$file" | "$JQ" -e 'has("tool_summary") | not' >/dev/null
done
# Qoder's native waiting notification has the same input boundary.
printf '%s' '{"session_id":"summary-session","notification_type":"permission_prompt","details":{"toolName":"Custom","input":{"questions":"hello"}}}' |
  sh "$root/bin/pitwall-hook" qoder-cn Notification
tail -n 1 "$PITWALL_HOME/events/qoder-cn.jsonl" | "$JQ" -e '.session_id=="summary-session" and (has("parse_error") | not)' >/dev/null
echo 'Tool summaries: malformed and unrelated questions preserve events; real questions retain bounded summaries'
