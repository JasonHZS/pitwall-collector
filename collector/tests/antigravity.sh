#!/bin/sh
# Exercise the installed hooks using Antigravity desktop and CLI wire formats.
set -eu
export PATH="/usr/bin:/bin"
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home with spaces" PITWALL_HOME="$tmp/home with spaces/.pitwall"
config="$HOME/.gemini/config/hooks.json"
mkdir -p "$HOME/.gemini/config"
printf '%s\n' '{"existing":{"enabled":false}}' > "$config"
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
test ! -d "$HOME/.gemini/antigravity"
test -x "$PITWALL_HOME/bin/pitwall-approval"
test -x "$PITWALL_HOME/bin/pitwall-hook-antigravity"
jq -e '
  .["pitwall-interactions"] as $g
  | ($g.SessionStart | length == 1) and ($g.PreInvocation | length == 1) and ($g.Stop | length == 1)
  | ($g.PreToolUse | map(.matcher) == ["^ask_question$", "^run_command$"])' "$config" >/dev/null
cp "$config" "$tmp/first"

# Migrate both legacy Pitwall entries (original combined matcher and ask_question-only matcher).
for legacy_matcher in '^(run_command|ask_question)$' '^ask_question$'; do
  jq --arg m "$legacy_matcher" --arg cmd "'$PITWALL_HOME/bin/pitwall-approval' antigravity" \
    '.["pitwall-interactions"] = {PreToolUse:[{matcher:$m,hooks:[{type:"command",command:$cmd,timeout:65}]}]}' \
    "$tmp/first" > "$config"
  printf '%s\n' 'previous version' > "$PITWALL_HOME/bin/pitwall-approval"
  printf '%s\n' 'previous hook' > "$PITWALL_HOME/bin/pitwall-hook-antigravity"
  sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
  cmp "$root/bin/pitwall-approval" "$PITWALL_HOME/bin/pitwall-approval"
  cmp "$root/bin/pitwall-hook-antigravity" "$PITWALL_HOME/bin/pitwall-hook-antigravity"
  cmp "$config" "$tmp/first"
done

sh "$root/install.sh" install antigravity >/dev/null
cmp "$config" "$tmp/first"

hook=$(jq -er '.["pitwall-interactions"].PreToolUse[0].hooks[0].command' "$config")
session_hook=$(jq -er '.["pitwall-interactions"].SessionStart[0].command' "$config")
pre_inv_hook=$(jq -er '.["pitwall-interactions"].PreInvocation[0].command' "$config")
stop_hook=$(jq -er '.["pitwall-interactions"].Stop[0].command' "$config")
dir="$PITWALL_HOME/approvals"
mkdir -p "$dir"

jq -n --arg brain "$HOME/.gemini/antigravity/brain/test-session" '{
  conversationId:"test-session", artifactDirectoryPath:$brain, lastUserInput:"private",
  toolCall:{id:"call_1",name:"run_command",args:{CommandLine:"pwd", BypassSandbox:true}}, workspacePaths:["/tmp"]}' > "$tmp/cmd"
jq '.toolCall={id:"call_q",name:"ask_question",args:{questions:[{question:"Pick",options:["A","B"],is_multi_select:true}]}}' "$tmp/cmd" > "$tmp/question"
jq '.artifactDirectoryPath |= sub("antigravity/";"antigravity-cli/")' "$tmp/cmd" > "$tmp/cli_cmd_unsandboxed"
jq 'del(.toolCall.args.BypassSandbox)' "$tmp/cli_cmd_unsandboxed" > "$tmp/cli_cmd_sandboxed"
jq '.artifactDirectoryPath |= sub("antigravity/";"antigravity-cli/")' "$tmp/question" > "$tmp/cli_question"
jq '.artifactDirectoryPath |= sub("antigravity/";"antigravity-ide/")' "$tmp/question" > "$tmp/ide_question"
jq '.artifactDirectoryPath |= sub("antigravity/";"antigravity-ide/")' "$tmp/cmd" > "$tmp/ide_cmd"

run() { sh -c "$hook" < "$tmp/$1" > "$tmp/output"; }
native() { run "$1"; jq -es '. == [{decision:"allow"}]' "$tmp/output" >/dev/null; }

# Pitwall not listening: everything delegates cleanly to native policy.
native question
native cli_question
native cli_cmd_unsandboxed

touch "$dir/listening"
# Desktop run_command (both sandboxed and unsandboxed) stays native.
native cmd
jq 'del(.toolCall.args.BypassSandbox)' "$tmp/cmd" > "$tmp/sandboxed"
native sandboxed
# IDE payloads always stay native.
native ide_question
native ide_cmd
# CLI sandboxed run_command in default auto mode stays native (no spurious prompts).
native cli_cmd_sandboxed
test ! -d "$dir/requests"

# Invalid question format falls back to native.
jq '.toolCall.args.questions[0].options = [{bogus:true}]' "$tmp/question" > "$tmp/invalid"
native invalid

# Both Desktop and CLI structured questions work end-to-end.
for fixture_name in question cli_question; do
  expected_variant="desktop"
  [ "$fixture_name" = cli_question ] && expected_variant="cli"
  for reply in answer malformed; do
    touch "$dir/listening"
    run "$fixture_name" &
    pid=$!
    tries=0
    while :; do
      set -- "$dir"/requests/*.json
      [ -f "$1" ] && break
      tries=$((tries+1)); [ "$tries" -lt 50 ] || exit 1
      sleep .1
    done
    jq -e --arg v "$expected_variant" '.session_id == "test-session" and .agent == "antigravity" and .variant == $v and (has("lastUserInput")|not)' "$1" >/dev/null
    id=$(jq -r .id "$1")
    jq -e '.tool_name == "ask_question" and .answer_format == "answers-v1" and .tool_input.questions[0] == {question:"Pick",multiSelect:true,options:[{label:"A"},{label:"B"}]}' "$1" >/dev/null
    if [ "$reply" = answer ]; then decision='{"answers":{"Pick":"A, B"}}'; else decision='{}'; fi
    printf '%s' "$decision" > "$tmp/reply"
    mv "$tmp/reply" "$dir/decisions/$id"
    wait "$pid"
    case "$reply" in
      answer) check='.decision == "deny" and (.reason | contains("A, B"))' ;;
      malformed) check='.decision == "allow"' ;;
    esac
    jq -es "length == 1 and (.[0] | $check)" "$tmp/output" >/dev/null
    test ! -e "$1" && test ! -e "$dir/decisions/$id"
  done
done

# CLI unsandboxed run_command in default auto mode: approve -> auto_approve, deny -> deny.
for decision in allow deny; do
  touch "$dir/listening"
  run cli_cmd_unsandboxed &
  pid=$!
  tries=0
  while :; do
    set -- "$dir"/requests/*.json
    [ -f "$1" ] && break
    tries=$((tries+1)); [ "$tries" -lt 50 ] || exit 1
    sleep .1
  done
  jq -e '.session_id == "test-session" and .agent == "antigravity" and .variant == "cli" and .tool_name == "run_command" and .tool_input.command == "pwd" and .tool_input.bypass_sandbox == true and (has("lastUserInput")|not)' "$1" >/dev/null
  id=$(jq -r .id "$1")
  printf '%s' "$decision" > "$tmp/reply"
  mv "$tmp/reply" "$dir/decisions/$id"
  wait "$pid"
  case "$decision" in
    allow) check='. == {decision:"auto_approve"}' ;;
    deny) check='.decision == "deny" and (.reason | length > 0)' ;;
  esac
  jq -es "length == 1 and (.[0] | $check)" "$tmp/output" >/dev/null
  test ! -e "$1" && test ! -e "$dir/decisions/$id"
done

# CLI sandboxed run_command in default mode (agentMode: "") is intercepted and can be approved.
mkdir -p "$HOME/.gemini/antigravity-cli"
printf '%s\n' '{"agentMode":"","toolPermission":"request-review"}' > "$HOME/.gemini/antigravity-cli/settings.json"
touch "$dir/listening"
run cli_cmd_sandboxed &
pid=$!
tries=0
while :; do
  set -- "$dir"/requests/*.json
  [ -f "$1" ] && break
  tries=$((tries+1)); [ "$tries" -lt 50 ] || exit 1
  sleep .1
done
jq -e '.tool_name == "run_command" and .variant == "cli" and .tool_input.command == "pwd"' "$1" >/dev/null
id=$(jq -r .id "$1")
printf 'allow' > "$tmp/reply"
mv "$tmp/reply" "$dir/decisions/$id"
wait "$pid"
jq -es '. == [{decision:"auto_approve"}]' "$tmp/output" >/dev/null

# CLI toolPermission=always-proceed delegates directly to native policy.
printf '%s\n' '{"toolPermission":"always-proceed"}' > "$HOME/.gemini/antigravity-cli/settings.json"
native cli_cmd_unsandboxed
rm -rf "$HOME/.gemini/antigravity-cli"

# Lifecycle hook bridge: Desktop payloads produce valid JSON and write nothing; CLI writes sanitized events.
jq -n --arg brain "$HOME/.gemini/antigravity/brain/desktop-1" '{
  conversationId:"desktop-1", artifactDirectoryPath:$brain, cwd:"/tmp", lastUserInput:"secret desktop prompt"}' > "$tmp/desktop_start"
sh -c "$session_hook" < "$tmp/desktop_start" > "$tmp/output"
jq -es '. == [{}]' "$tmp/output" >/dev/null
sh -c "$stop_hook" < "$tmp/desktop_start" > "$tmp/output"
jq -es '. == [{decision:"stop"}]' "$tmp/output" >/dev/null
test ! -e "$PITWALL_HOME/events/antigravity.jsonl"

jq -n --arg brain "$HOME/.gemini/antigravity-cli/brain/cli-1" '{
  conversationId:"cli-1", artifactDirectoryPath:$brain, cwd:"/tmp/project",
  lastUserInput:"  First line prompt\nsecond private line"}' > "$tmp/cli_start"
TERM_PROGRAM="Apple_Terminal" sh -c "$session_hook" < "$tmp/cli_start" > "$tmp/output"
jq -es '. == [{}]' "$tmp/output" >/dev/null
TERM_PROGRAM="Apple_Terminal" sh -c "$pre_inv_hook" < "$tmp/cli_start" > "$tmp/output"
jq -es '. == [{}]' "$tmp/output" >/dev/null
jq '. + {terminationReason:"ERROR", error:"network failed", fullyIdle:true}' "$tmp/cli_start" > "$tmp/cli_stop"
sh -c "$stop_hook" < "$tmp/cli_stop" > "$tmp/output"
jq -es '. == [{decision:"stop"}]' "$tmp/output" >/dev/null
jq -es '
  length == 3
  and .[0].event == "SessionStart" and .[0].session_id == "cli-1" and .[0].cwd == "/tmp/project"
  and all(.[]; (has("prompt_head") or has("lastUserInput")) | not)
  and (tostring | contains("First line prompt") or contains("second private line") | not)
  and .[0].ctx.term_program == "Apple_Terminal" and (.[0].ctx.ppid | type == "number")
  and .[1].event == "PreInvocation"
  and .[2].event == "Stop" and .[2].reason == "ERROR" and .[2].error == "network failed" and .[2].status == "idle"' \
  "$PITWALL_HOME/events/antigravity.jsonl" >/dev/null
if /bin/ps -o pid= -p "$$" >/dev/null 2>&1; then
  jq -es '.[0].ctx.proc | type == "object"' "$PITWALL_HOME/events/antigravity.jsonl" >/dev/null
fi

sh "$root/install.sh" uninstall antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null

# An explicit uninstall survives the next discovery. Manual installation enables it again.
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null
sh "$root/install.sh" install antigravity >/dev/null
jq '.["pitwall-interactions"].enabled = false' "$tmp/first" > "$tmp/disabled"
cp "$tmp/disabled" "$config"
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
cmp "$config" "$tmp/disabled"

# Global uninstall after auto-install (without ~/.gemini/antigravity) must keep the opt-out marker.
sh "$root/install.sh" uninstall >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null
test -e "$PITWALL_HOME/antigravity-hooks-uninstalled"
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null

# Multi-agent explicit install and uninstall include antigravity even before first launch.
sh "$root/install.sh" install claude-code antigravity >/dev/null
jq -e 'has("pitwall-interactions")' "$config" >/dev/null
sh "$root/install.sh" uninstall claude-code antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null
test -e "$PITWALL_HOME/antigravity-hooks-uninstalled"

# Global uninstall when Antigravity was never installed leaves no opt-out marker.
rm -f "$PITWALL_HOME/antigravity-hooks-uninstalled"
sh "$root/install.sh" uninstall >/dev/null
test ! -e "$PITWALL_HOME/antigravity-hooks-uninstalled"
