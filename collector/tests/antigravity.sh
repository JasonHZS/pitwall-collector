#!/bin/sh
# Exercise the installed hook using the desktop PreToolUse wire format.
set -eu
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
jq -e '.["pitwall-interactions"].PreToolUse | length == 1 and .[0].matcher == "^ask_question$"' "$config" >/dev/null
cp "$config" "$tmp/first"
jq '.["pitwall-interactions"].PreToolUse[0].matcher = "^(run_command|ask_question)$"' "$config" > "$tmp/legacy"
cp "$tmp/legacy" "$config"
printf '%s\n' 'previous version' > "$PITWALL_HOME/bin/pitwall-approval"
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
cmp "$root/bin/pitwall-approval" "$PITWALL_HOME/bin/pitwall-approval"
cmp "$config" "$tmp/first"
sh "$root/install.sh" install antigravity >/dev/null
cmp "$config" "$tmp/first"
hook=$(jq -er '.["pitwall-interactions"].PreToolUse[0].hooks[0].command' "$config")
dir="$PITWALL_HOME/approvals"
mkdir -p "$dir"
jq -n --arg brain "$HOME/.gemini/antigravity/brain/test-session" '{
  conversationId:"test-session", artifactDirectoryPath:$brain, lastUserInput:"private",
  toolCall:{name:"run_command",args:{CommandLine:"pwd", BypassSandbox:true}}, workspacePaths:["/tmp"]}' > "$tmp/cmd"
jq '.toolCall={name:"ask_question",args:{questions:[{question:"Pick",options:["A","B"],is_multi_select:true}]}}' "$tmp/cmd" > "$tmp/question"
run() { sh -c "$hook" < "$tmp/$1" > "$tmp/output"; }
native() { run "$1"; jq -es '. == [{decision:"allow"}]' "$tmp/output" >/dev/null; }
native question
touch "$dir/listening"
# Open sessions may still invoke the original command matcher. Neither kind of command creates a request.
native cmd
jq 'del(.toolCall.args.BypassSandbox)' "$tmp/cmd" > "$tmp/sandboxed"
native sandboxed
test ! -d "$dir/requests"
jq '.artifactDirectoryPath |= sub("antigravity/";"antigravity-cli/")' "$tmp/question" > "$tmp/cli"
native cli
jq '.toolCall.args.questions[0].options = [{bogus:true}]' "$tmp/question" > "$tmp/invalid"
native invalid
for reply in answer malformed; do
  touch "$dir/listening"
  run question &
  pid=$!
  tries=0
  while :; do
    set -- "$dir"/requests/*.json
    [ -f "$1" ] && break
    tries=$((tries+1)); [ "$tries" -lt 50 ] || exit 1
    sleep .1
  done
  jq -e '.session_id == "test-session" and .agent == "antigravity" and (has("lastUserInput")|not)' "$1" >/dev/null
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
sh "$root/install.sh" uninstall antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null

# An explicit uninstall survives the next discovery. Manual installation enables it again.
sh "$root/install.sh" auto-install-antigravity antigravity >/dev/null
jq -e '. == {existing:{enabled:false}}' "$config" >/dev/null
sh "$root/install.sh" install antigravity >/dev/null
jq '.["pitwall-interactions"].enabled = false' "$tmp/legacy" > "$tmp/disabled"
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
