#!/bin/sh
# Isolated ZCode install, privacy and decision-protocol tests; never runs a model.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-zcode.XXXXXX")
export HOME="$tmp/home" PITWALL_HOME="$tmp/pitwall"
child=''
cleanup() { [ -z "$child" ] || kill "$child" 2>/dev/null || :; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$HOME/.zcode/cli" "$PITWALL_HOME/approvals/requests" "$PITWALL_HOME/approvals/decisions"
cfg="$HOME/.zcode/cli/config.json"
printf '%s' '{"provider":"keep","hooks":{"enabled":true,"events":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true user"}]}]}}}' > "$cfg"
sh "$root/install.sh" install zcode > /dev/null
/usr/bin/jq -e '.provider=="keep" and .hooks.enabled==true and (.hooks.events.PermissionRequest[0].hooks[0] | .type=="process" and .timeoutMs==65000) and .hooks.events.Stop[0].hooks[0].command=="/usr/bin/true user"' "$cfg" >/dev/null
cp "$cfg" "$tmp/installed"
sh "$root/install.sh" install zcode > /dev/null
cmp "$cfg" "$tmp/installed"
sh "$root/install.sh" uninstall zcode > /dev/null
/usr/bin/jq -e '.hooks.events | keys==["Stop"]' "$cfg" >/dev/null
printf '%s' '{"hooks":{"enabled":false,"events":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true user"}]}]}}}' > "$cfg"
cp "$cfg" "$tmp/disabled"
if sh "$root/install.sh" install zcode >/dev/null 2>&1; then echo 'activated disabled third-party hooks' >&2; exit 1; fi
cmp "$cfg" "$tmp/disabled"
# Uninstall puts back a hooks switch that Pitwall turned on, unless other hooks were added since.
printf '%s' '{"provider":"keep"}' > "$cfg"
sh "$root/install.sh" install zcode > /dev/null
/usr/bin/jq -e '.hooks.enabled == true' "$cfg" >/dev/null
sh "$root/install.sh" install zcode > /dev/null
sh "$root/install.sh" uninstall zcode > /dev/null
/usr/bin/jq -e '. == {"provider":"keep"}' "$cfg" >/dev/null
test ! -e "$PITWALL_HOME/zcode-hooks-state.json"
printf '%s' '{"hooks":{"enabled":false}}' > "$cfg"
sh "$root/install.sh" install zcode > /dev/null
sh "$root/install.sh" uninstall zcode > /dev/null
/usr/bin/jq -e '. == {"hooks":{"enabled":false}}' "$cfg" >/dev/null
printf '%s' '{}' > "$cfg"
sh "$root/install.sh" install zcode > /dev/null
/usr/bin/jq '.hooks.events.Stop = [{"hooks":[{"type":"command","command":"/usr/bin/true later"}]}]' "$cfg" > "$tmp/later" && mv "$tmp/later" "$cfg"
sh "$root/install.sh" uninstall zcode > /dev/null
/usr/bin/jq -e '.hooks.enabled == true and (.hooks.events | keys) == ["Stop"]' "$cfg" >/dev/null
test ! -e "$PITWALL_HOME/zcode-hooks-state.json"

payload='{"session_id":"session-z","turnId":"turn-z","timestamp":"2026-11-08T03:00:01.123Z","hook_event_name":"PermissionRequest","cwd":"/tmp/project","tool_name":"Bash","tool_use_id":"call-z","tool_input":{"command":"touch /tmp/test"}}'
printf '%s' "$payload" | sh "$root/bin/pitwall-hook" zcode PermissionRequest
file="$PITWALL_HOME/events/zcode.jsonl"
/usr/bin/jq -e '.turn_id=="turn-z" and .tool_use_id=="call-z" and .tool_summary=="touch /tmp/test" and .ts==1794106801123' "$file" >/dev/null
printf '%s' "$payload" | /usr/bin/jq '.tool_name="AskUserQuestion" | .tool_input={answers:{secret:"PRIVATE_ANSWER"}} | .error="PRIVATE_ANSWER" | .message="PRIVATE_ANSWER"' |
    sh "$root/bin/pitwall-hook" zcode PostToolUseFailure
if /usr/bin/grep -q PRIVATE_ANSWER "$file"; then echo 'question answer leaked to spool' >&2; exit 1; fi

appr="$PITWALL_HOME/approvals"
for decision in allow deny; do
  touch "$appr/listening"
  printf '%s' "$payload" | sh "$root/bin/pitwall-approval" zcode > "$tmp/$decision.out" & child=$!
  n=0
  while :; do
    set -- "$appr"/requests/zcode.session-z.*.json
    [ ! -e "$1" ] || break
    n=$((n+1)); [ "$n" -lt 60 ]; sleep 0.05
  done
  request=$1
  /usr/bin/jq -e '.turn_id=="turn-z" and .tool_use_id=="call-z" and .agent=="zcode"' "$request" >/dev/null
  id=$(/usr/bin/jq -r .id "$request")
  printf '%s' "$decision" > "$appr/decisions/$id"
  wait "$child"; child=''
  /usr/bin/jq -e --arg decision "$decision" '.hookSpecificOutput.hookEventName=="PermissionRequest" and .hookSpecificOutput.decision.behavior==$decision' "$tmp/$decision.out" >/dev/null
  test ! -e "$request"; test ! -e "$appr/decisions/$id"
done
# A matching completion retracts the request, without cancelling another call.
touch "$appr/listening"
printf '%s' "$payload" | sh "$root/bin/pitwall-approval" zcode > "$tmp/retracted.out" & child=$!
n=0
while :; do
  set -- "$appr"/requests/zcode.session-z.*.json
  [ ! -e "$1" ] || break
  n=$((n+1)); [ "$n" -lt 60 ]; sleep 0.05
done
request=$1
printf '%s' "$payload" | /usr/bin/jq '.tool_use_id="other"' | sh "$root/bin/pitwall-hook" zcode PostToolUse
test -e "$request"
printf '%s' "$payload" | sh "$root/bin/pitwall-hook" zcode PostToolUse
test ! -e "$request"
wait "$child"; child=''
test ! -s "$tmp/retracted.out"
# Questions use the shared text-keyed form and native updatedInput, never an Allow click.
question_payload=$(printf '%s' "$payload" | /usr/bin/jq '.tool_name="AskUserQuestion" | .tool_input={
  questions:[
    {question:"Pick one?",header:"One",options:[{label:"A",description:"First"},{label:"B",description:"Second"}]},
    {question:"Pick colors?",header:"Colors",multiSelect:true,options:[{label:"Red",description:"Red"},{label:"Blue",description:"Blue"}]},
    {question:"Anything else?",header:"Other",options:[{label:"Yes",description:"Yes"},{label:"No",description:"No"}]}
  ],metadata:{source:"test"}}')
for mode in answered empty blank missing foreign tool_allow withdrawn no_listener; do
  touch "$appr/listening"
  printf '%s' "$question_payload" | sh "$root/bin/pitwall-approval" zcode > "$tmp/question-$mode.out" & child=$!
  n=0
  while :; do
    set -- "$appr"/requests/zcode.session-z.*.json
    [ ! -e "$1" ] || break
    n=$((n+1)); [ "$n" -lt 60 ]; sleep 0.05
  done
  request=$1
  /usr/bin/jq -e '.tool_name=="AskUserQuestion" and .answer_format=="answers-v1" and (.tool_input.questions | length)==3' "$request" >/dev/null
  id=$(/usr/bin/jq -r .id "$request")
  case "$mode" in
    answered) printf '%s' '{"answers":{"Pick one?":"B","Pick colors?":"Red, Blue","Anything else?":"PRIVATE_ANSWER"}}' > "$appr/decisions/$id" ;;
    blank) printf '%s' '{"answers":{"Pick one?":"B","Pick colors?":"Red","Anything else?":" "}}' > "$appr/decisions/$id" ;;
    empty) printf '%s' '{"answers":{}}' > "$appr/decisions/$id" ;;
    missing) printf '%s' '{"answers":{"Pick one?":"B"}}' > "$appr/decisions/$id" ;;
    foreign) printf '%s' '{"answers":{"Wrong question?":"B"}}' > "$appr/decisions/$id" ;;
    tool_allow) printf '%s' allow > "$appr/decisions/$id" ;;
    withdrawn)
      printf '%s' "$question_payload" | /usr/bin/jq '.tool_input.answers={"Anything else?":"PRIVATE_ANSWER"}' |
        sh "$root/bin/pitwall-hook" zcode PostToolUse ;;
    no_listener) rm "$appr/listening" ;;
  esac
  wait "$child"; child=''
  if [ "$mode" = answered ]; then
    /usr/bin/jq -e '.hookSpecificOutput.hookEventName=="PermissionRequest" and .hookSpecificOutput.decision.behavior=="allow"
      and .hookSpecificOutput.decision.updatedInput.answers=={"Pick one?":"B","Pick colors?":"Red, Blue","Anything else?":"PRIVATE_ANSWER"}
      and .hookSpecificOutput.decision.updatedInput.metadata.source=="test"
      and (.hookSpecificOutput.decision.updatedInput.questions | length)==3' "$tmp/question-$mode.out" >/dev/null
  else
    test ! -s "$tmp/question-$mode.out"
  fi
  test ! -e "$request"; test ! -e "$appr/decisions/$id"
done
# Unknown forms and previews remain native; a blank/invalid reply is never an empty answer map.
for shape in malformed duplicate preview; do
  touch "$appr/listening"
  case "$shape" in
    malformed) changed=$(printf '%s' "$question_payload" | /usr/bin/jq '.tool_input.questions="unknown"') ;;
    duplicate) changed=$(printf '%s' "$question_payload" | /usr/bin/jq '.tool_input.questions[1].question="Pick one?"') ;;
    preview) changed=$(printf '%s' "$question_payload" | /usr/bin/jq '.tool_input.questions[0].options[0].preview="artifact"') ;;
  esac
  printf '%s' "$changed" | sh "$root/bin/pitwall-approval" zcode > "$tmp/question-$shape.out"
  test ! -s "$tmp/question-$shape.out"
done
if /usr/bin/grep -q PRIVATE_ANSWER "$file"; then echo 'answer leaked to spool' >&2; exit 1; fi
rm "$appr/listening"
printf '%s' "$payload" | sh "$root/bin/pitwall-approval" zcode > "$tmp/absent"
test ! -s "$tmp/absent"
# A separately started CLI/test process is not the desktop bridge.
before=$(wc -l < "$file")
printf '%s' "$payload" | sh "$root/bin/pitwall-hook-zcode"
test "$(wc -l < "$file")" = "$before"
echo 'ZCode: install, privacy, allow/deny, native structured answers, withdrawal and fallback passed'
