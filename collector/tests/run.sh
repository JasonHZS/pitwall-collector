#!/bin/sh
# 采集层自测：在临时 HOME 里跑 install → 喂样例 payload → 查看 → uninstall，不碰真实配置。
#   sh collector/tests/run.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
JQ=/usr/bin/jq
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export PITWALL_HOME="$HOME/.pitwall"
HOOK="$PITWALL_HOME/bin/pitwall-hook"
EVENTS="$PITWALL_HOME/bin/pitwall-events"
SPOOL="$PITWALL_HOME/events"

fails=0
ok() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
jqcheck() { desc=$1 file=$2 prog=$3; check "$desc" "$JQ" -e "$prog" "$file"; }
count_ours() { "$JQ" '[.. | objects | select(has("command")) | select(.command | contains("pitwall-hook"))] | length' "$1"; }

# ---- 预置：含用户自己的 hook 和其它设置，验证不被破坏 ----
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.cursor" "$HOME/.pi/agent/extensions" "$HOME/.config/devin"
printf '%s\n' '{"env":{"FOO":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop-hook"}]}]}}' > "$HOME/.claude/settings.json"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/usr/bin/true user-hook"}]}]}}' > "$HOME/.codex/hooks.json"
printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/usr/bin/true user-hook","type":"command"}]}}' > "$HOME/.cursor/hooks.json"
printf '%s\n' '{"version":1,"agent":{"model":"swe-2"},"permissions":{"allow":["Read(**)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true user-devin-hook"}]}]}}' > "$HOME/.config/devin/config.json"
for f in .claude/settings.json .codex/hooks.json .cursor/hooks.json .config/devin/config.json; do
  "$JQ" -S . "$HOME/$f" > "$tmp/seed_$(printf '%s' "$f" | tr '/.' '__')"
done

echo "install"
check "install 成功" sh "$root/install.sh" install
check "hook 脚本可执行" test -x "$HOOK"
check "查看工具可执行" test -x "$EVENTS"
C="$HOME/.claude/settings.json" X="$HOME/.codex/hooks.json" R="$HOME/.cursor/hooks.json"
jqcheck "claude：保留 env" "$C" '.env.FOO == "1"'
jqcheck "claude：保留用户 Stop hook" "$C" '[.hooks.Stop[].hooks[].command] | index("echo user-stop-hook") != null'
check "claude：12 个 pitwall hook" test "$(count_ours "$C")" = 12
jqcheck "claude：全部 async" "$C" '[.. | objects | select(has("command")) | select(.command | contains("pitwall-hook")) | .async] | all'
jqcheck "claude：工具类事件带 matcher *" "$C" '[.hooks.PreToolUse[] | select(.hooks[0].command | contains("pitwall-hook")) | .matcher] == ["*"]'
jqcheck "claude：PermissionRequest 已登记" "$C" '.hooks.PermissionRequest | length == 1'
check "codex：7 个 pitwall hook" test "$(count_ours "$X")" = 7
jqcheck "codex：保留用户 hook" "$X" '[.hooks.Stop[].hooks[].command] | index("/usr/bin/true user-hook") != null'
jqcheck "codex：SessionEnd 不设 async（Codex 不支持）" "$X" '.hooks.SessionEnd[0].hooks[0] | has("async") | not'
check "cursor：6 个 pitwall hook" test "$(count_ours "$R")" = 6
jqcheck "cursor：保留用户 hook 与 version" "$R" '.version == 1 and ([.hooks.stop[].command] | index("/usr/bin/true user-hook") != null)'
jqcheck "cursor：不注册带决策语义的 before* 权限 hook" "$R" '.hooks | has("beforeShellExecution") or has("beforeMCPExecution") or has("preToolUse") | not'
check "pi：扩展已放置" test -f "$HOME/.pi/agent/extensions/pitwall.ts"
D="$HOME/.config/devin/config.json"
check "devin：8 个 pitwall hook" test "$(count_ours "$D")" = 8
jqcheck "devin：保留模型、权限与用户 hook" "$D" '.agent.model == "swe-2" and .permissions.allow == ["Read(**)"] and ([.hooks.Stop[].hooks[].command] | index("/usr/bin/true user-devin-hook") != null)'
# Devin 遇到未知事件名会整段忽略 hooks（包括用户自己的），所以只能登记它认识的 8 个。
jqcheck "devin：只登记 Devin 认识的事件" "$D" '.hooks | keys - ["PreToolUse","PostToolUse","UserPromptSubmit","Stop","PostCompaction","SessionStart","SessionEnd","PermissionRequest"] == []'
jqcheck "devin：不写 async / matcher" "$D" '[.hooks[][] | select(any(.hooks[]?; .command | contains("pitwall-hook"))) | (has("matcher") or any(.hooks[]; has("async")))] | any | not'

sums() { shasum "$C" "$X" "$R" "$D" "$HOME/.pi/agent/extensions/pitwall.ts"; }
before=$(sums)
sh "$root/install.sh" install >/dev/null
check "重复 install 结果不变" test "$before" = "$(sums)"
# 其它工具在 pitwall 之后追加 hook（本机 Otty 即如此）时，重复安装也不调换顺序。
for f in "$C" "$X"; do
  "$JQ" '.hooks.Stop += [{"hooks":[{"type":"command","command":"later-tool-hook"}]}]' "$f" > "$f.new" && mv "$f.new" "$f"
done
"$JQ" '.hooks.stop += [{"command":"later-tool-hook","type":"command"}]' "$R" > "$R.new" && mv "$R.new" "$R"
later=$(sums)
sh "$root/install.sh" install >/dev/null
check "他人后追加 hook 时重复 install 不改写配置" test "$later" = "$(sums)"
jqcheck "claude：后追加的 hook 仍排在 pitwall 之后" "$C" '[.hooks.Stop[].hooks[].command] | (index("later-tool-hook") > (map(contains("pitwall-hook")) | index(true)))'
for f in "$C" "$X"; do
  "$JQ" '.hooks.Stop |= map(select(.hooks[0].command != "later-tool-hook"))' "$f" > "$f.new" && mv "$f.new" "$f"
done
"$JQ" '.hooks.stop |= map(select(.command != "later-tool-hook"))' "$R" > "$R.new" && mv "$R.new" "$R"
check "移除后追加的 hook 后回到原状" test "$before" = "$(sums)"
"$JQ" -c . "$C" > "$C.compact" && mv "$C.compact" "$C"
compact=$(shasum "$C")
sh "$root/install.sh" install claude-code >/dev/null
check "只有格式不同时不重写配置" test "$compact" = "$(shasum "$C")"

echo "hook 脚本"
feed() { # <agent> <event> <payload>；断言 stdout 为空
  out=$(printf '%s' "$3" | "$HOOK" "$1" "$2")
  [ -z "$out" ] || fail "$1 $2 向 stdout 输出了内容：$out"
}
long=$(printf 'x%.0s' $(seq 1 200))
feed claude-code SessionStart '{"session_id":"claude-sess-1","cwd":"/tmp/proj-a","hook_event_name":"SessionStart","source":"startup","model":"claude-x","transcript_path":"/tmp/t.jsonl"}'
feed claude-code UserPromptSubmit "{\"session_id\":\"claude-sess-1\",\"cwd\":\"/tmp/proj-a\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"\\n  修复登录 $long\\n第二行 SECRET-PROMPT\"}"
feed claude-code PreToolUse '{"session_id":"claude-sess-1","cwd":"/tmp/proj-a","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"curl -H SECRET-TOKEN-123"}}'
feed claude-code PermissionRequest '{"session_id":"claude-sess-1","cwd":"/tmp/proj-a","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\n  rm -rf build/  \nSECRET-TOKEN-123"},"permission_mode":"default"}'
feed claude-code Stop "{\"session_id\":\"claude-reply\",\"cwd\":\"/tmp/proj-a\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"已修复登录。\\n\\n  原因是 token 过期 $long SECRET-REPLY-TAIL\"}"
feed claude-code PostToolUseFailure '{"session_id":"claude-interrupt","cwd":"/tmp/proj-a","hook_event_name":"PostToolUseFailure","tool_name":"Bash","prompt_id":"prompt-1","agent_id":"agent-7","agent_type":"general-purpose","is_interrupt":true,"error":"interrupted","tool_input":{"command":"SECRET-TOKEN-123"}}'
feed claude-code UserPromptSubmit '{"session_id":"claude-bg-running","cwd":"/tmp/proj-a","hook_event_name":"UserPromptSubmit","prompt":"run background agent"}'
feed claude-code Stop '{"session_id":"claude-bg-running","cwd":"/tmp/proj-a","hook_event_name":"Stop","background_tasks":["malformed-element",{"id":"task-1","type":"subagent","status":"running","description":"SECRET-SUBAGENT-DESCRIPTION","command":"SECRET-SUBAGENT-COMMAND"}]}'
feed claude-code UserPromptSubmit '{"session_id":"claude-bg-done","cwd":"/tmp/proj-a","hook_event_name":"UserPromptSubmit","prompt":"finish background agent"}'
feed claude-code Stop '{"session_id":"claude-bg-done","cwd":"/tmp/proj-a","hook_event_name":"Stop","background_tasks":[{"id":"task-2","type":"subagent","status":"running"}]}'
feed claude-code Stop '{"session_id":"claude-bg-done","cwd":"/tmp/proj-a","hook_event_name":"Stop","background_tasks":[{"id":"task-2","type":"subagent","status":"completed"}]}'
feed claude-code Stop '{"session_id":"claude-bg-shell","cwd":"/tmp/proj-a","hook_event_name":"Stop","background_tasks":[{"id":"task-3","type":"shell","status":"running"}]}'
feed codex UserPromptSubmit '{"session_id":"codex-wrapped","cwd":"/tmp/proj-b","hook_event_name":"UserPromptSubmit","prompt":"<in-app-browser-context source=\"ambient-ui-state\">\nurl: SECRET-CONTEXT\n</in-app-browser-context>\n\n修一下按钮"}'
feed codex UserPromptSubmit "$("$JQ" -nc '{session_id: "codex-many-wrappers", prompt: (([range(1;10) | "<ctx\(.)>SECRET-CONTEXT</ctx\(.)>"] | join("")) + "\n真正的用户请求")}')"
# Chrome 插件宿主（hook 的祖父进程）用指向 sh 的同名软链模拟；hook 与宿主之间隔一层，与 Codex 一致。
mkdir -p "$tmp/chrome-host"
ln -s /bin/bash "$tmp/chrome-host/ChatGPT for Chrome"
cfeed() { # <payload>：在 Chrome 插件宿主下发 codex UserPromptSubmit
  out=$(printf '%s' "$1" | "$tmp/chrome-host/ChatGPT for Chrome" -c '/bin/sh -c "\"\$0\" codex UserPromptSubmit; :" "$0"; :' "$HOOK")
  [ -z "$out" ] || fail "chrome UserPromptSubmit 向 stdout 输出了内容：$out"
}
cfeed '{"session_id":"codex-chrome","prompt":"\n# Chrome tabs:\n- The user has the Chrome extension side panel open.\n- Current URL: https://example.com/SECRET-TAB\n\n## My request:\n\n检查 SQL 的新增用户条件\n第二行 SECRET-PROMPT"}'
cfeed '{"session_id":"codex-chrome-wrapped","prompt":"<context>SECRET-CONTEXT</context>\r\n# Chrome tabs:\r\n- SECRET-TAB\r\n\r\n## My request:\r\n修复按钮\r\n## My request:\r\nSECRET-PROMPT"}'
cfeed '{"session_id":"codex-chrome-empty","prompt":"# Chrome tabs:\n- SECRET-TAB\n\n## My request:\n   \n"}'
cfeed '{"session_id":"codex-chrome-no-tabs","prompt":"# Chrome tabs:\n## My request:\n没有标签页时的请求"}'
cfeed '{"session_id":"codex-chrome-inline","prompt":"# Chrome tabs:\n- SECRET-TAB\n## My request: 同一行的请求"}'
cfeed '{"session_id":"codex-chrome-bare","prompt":"# Chrome tabs:\n- SECRET-TAB\n## My request:"}'
cfeed '{"session_id":"codex-chrome-lookalike","prompt":"# Chrome tabs:\n- example\n## My requests: 不是分隔符"}'
cfeed '{"session_id":"codex-chrome-literal","prompt":"# Chrome tabs:\n这是用户自己写的标题"}'
cfeed '{"session_id":"codex-chrome-not-leading","prompt":"请解释下面的格式\n# Chrome tabs:\n- example\n\n## My request:\n这里不是本轮请求"}'
feed codex UserPromptSubmit '{"session_id":"codex-cli-chrome-shaped","prompt":"# Chrome tabs:\n- example\n\n## My request:\n这是 CLI 用户粘贴的正文"}'
feed claude-code UserPromptSubmit '{"session_id":"claude-chrome-literal","prompt":"# Chrome tabs:\n- example\n\n## My request:\n这是普通用户正文"}'
feed codex UserPromptSubmit '{"session_id":"codex-sess-1","turn_id":"turn-1","cwd":"/tmp/proj-b","hook_event_name":"UserPromptSubmit","prompt":"add tests","permission_mode":"on-request"}'
feed codex PermissionRequest '{"session_id":"codex-sess-1","turn_id":"turn-1","cwd":"/tmp/proj-b","hook_event_name":"PermissionRequest","tool_name":"exec_command","tool_input":{"cmd":"SECRET-TOKEN-123"}}'
feed codex Stop '{"session_id":"codex-sess-2","turn_id":"turn-9","cwd":"/tmp/proj-c","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"SECRET-REPLY"}'
feed cursor beforeSubmitPrompt '{"conversation_id":"cursor-conv-1","generation_id":"gen-1","hook_event_name":"beforeSubmitPrompt","workspace_roots":["/tmp/proj-d"],"prompt":"refactor","user_email":"someone@example.com"}'
feed cursor stop '{"conversation_id":"cursor-conv-1","generation_id":"gen-1","hook_event_name":"stop","status":"error","workspace_roots":["/tmp/proj-d"],"user_email":"someone@example.com","loop_count":0}'
feed claude-code SessionStart '{"session_id":"cursor-via-claude","conversation_id":"cursor-via-claude","hook_event_name":"sessionStart","cursor_version":"3.19.13","workspace_roots":["/tmp/proj-d"]}'
feed codex PostToolUse 'this is not json'
# Devin 的 payload 不带 cwd / transcript_path，工作目录来自它设置的 DEVIN_PROJECT_DIR。
dfeed() { # <agent> <event> <payload>
  out=$(printf '%s' "$3" | DEVIN_PROJECT_DIR=/tmp/proj-f "$HOOK" "$1" "$2")
  [ -z "$out" ] || fail "$1 $2 向 stdout 输出了内容：$out"
}
dfeed devin SessionStart '{"hook_event_name":"SessionStart","session_id":"devin-sess-1","source":"startup"}'
dfeed devin UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","session_id":"devin-sess-1","prompt_id":"dp-1","prompt":"整理测试\n第二行 SECRET-DEVIN"}'
dfeed devin PermissionRequest '{"hook_event_name":"PermissionRequest","session_id":"devin-sess-1","prompt_id":"dp-1","tool_name":"exec","tool_use_id":"t1","tool_input":{"command":"SECRET-DEVIN"}}'
dfeed devin Stop '{"hook_event_name":"Stop","session_id":"devin-sess-1","prompt_id":"dp-1","stop_hook_active":false,"last_assistant_message":"SECRET-DEVIN"}'
dfeed claude-code SessionStart '{"hook_event_name":"SessionStart","session_id":"devin-via-claude","source":"startup"}'
dfeed claude-code SessionStart '{"hook_event_name":"SessionStart","session_id":"claude-in-devin-shell","source":"startup","cwd":"/tmp/proj-a","transcript_path":"/tmp/t2.jsonl"}'
feed claude-code Notification '[1,2,3]'

CL="$SPOOL/claude-code.jsonl" CX="$SPOOL/codex.jsonl" CU="$SPOOL/cursor.jsonl" DV="$SPOOL/devin.jsonl"
check "claude spool 15 行" test "$(wc -l < "$CL" | tr -d ' ')" = 15
check "每行都是合法 JSON" sh -c "cat '$SPOOL'/*.jsonl | '$JQ' -e . >/dev/null"
check "除约定的摘要外，不含 tool_input / prompt 正文 / 回复 / 邮箱" sh -c "! grep -q -e SECRET -e someone@example.com '$SPOOL'/*.jsonl"
check "prompt_head 取首个非空行且 ≤ 81 字" "$JQ" -se '[.[] | select(.event == "UserPromptSubmit")][0].prompt_head | startswith("修复登录") and (length <= 81)' "$CL"
jqcheck "开头的注入块被跳过，只记标签名" "$CX" 'select(.session_id == "codex-wrapped") | .prompt_head == "修一下按钮" and .prompt_wrappers == ["in-app-browser-context"]'
jqcheck "超过 8 个注入块仍全部跳过，标签名仅记前 8 个" "$CX" 'select(.session_id == "codex-many-wrappers") | .prompt_head == "真正的用户请求" and .prompt_wrappers == [range(1;9) | "ctx\(.)"]'
jqcheck "Chrome 上下文后提取实际请求，不记录标签页 URL" "$CX" 'select(.session_id == "codex-chrome") | .prompt_head == "检查 SQL 的新增用户条件"'
jqcheck "Chrome 支持前置包装与 CRLF，保留首个请求后的正文" "$CX" 'select(.session_id == "codex-chrome-wrapped") | .prompt_head == "修复按钮" and .prompt_wrappers == ["context"]'
jqcheck "Chrome 请求为空时摘要缺失，不退回上下文" "$CX" 'select(.session_id == "codex-chrome-empty" or .session_id == "codex-chrome-bare") | .prompt_head == null'
jqcheck "Chrome 标签页列表为空时仍提取请求" "$CX" 'select(.session_id == "codex-chrome-no-tabs") | .prompt_head == "没有标签页时的请求"'
jqcheck "Chrome 请求与分隔符同行时仍提取" "$CX" 'select(.session_id == "codex-chrome-inline") | .prompt_head == "同一行的请求"'
jqcheck "相似但不同的分隔符不视为请求" "$CX" 'select(.session_id == "codex-chrome-lookalike") | .prompt_head == "# Chrome tabs:"'
jqcheck "没有完整 Chrome 区块时不剥掉用户标题" "$CX" 'select(.session_id == "codex-chrome-literal") | .prompt_head == "# Chrome tabs:"'
jqcheck "正文中的 Chrome 标题不影响请求首行" "$CX" 'select(.session_id == "codex-chrome-not-leading") | .prompt_head == "请解释下面的格式"'
jqcheck "非 Chrome 宿主的 Codex 不按插件区块剥离" "$CX" 'select(.session_id == "codex-cli-chrome-shaped") | .prompt_head == "# Chrome tabs:"'
jqcheck "其它 Agent 的同名标题不视为插件上下文" "$CL" 'select(.session_id == "claude-chrome-literal") | .prompt_head == "# Chrome tabs:"'
jqcheck "记录 prompt_id / agent_id / agent_type / is_interrupt" "$CL" 'select(.event == "PostToolUseFailure") | .prompt_id == "prompt-1" and .agent_id == "agent-7" and .agent_type == "general-purpose" and .is_interrupt == true'
jqcheck "claude PermissionRequest 只记命令首个非空行" "$CL" 'select(.event == "PermissionRequest") | .tool_summary == "rm -rf build/" and .tool_name == "Bash"'
jqcheck "claude Stop 的回复压成一行、≤ 161 字" "$CL" 'select(.session_id == "claude-reply") | (.reply_head | startswith("已修复登录。 原因是 token 过期 xxx") and length <= 161)'
check "codex / devin 不记回复与工具摘要" sh -c "! grep -q -e reply_head -e tool_summary '$CX' '$DV'"
jqcheck "记录 payload 字段名" "$CL" 'select(.event == "PreToolUse") | .payload_keys | index("tool_input") != null'
jqcheck "后台 subagent 只记布尔值与形状，不记详情" "$CL" 'select(.session_id == "claude-bg-running" and .event == "Stop") | .background_subagent_running == true and .background_task_shapes == ["?", "subagent/running"] and (has("background_tasks") | not)'
check "background_tasks 含非对象元素也不丢事件" "$JQ" -se '[.[] | select(.session_id == "claude-bg-running" and .event == "Stop")] | length == 1 and .[0].parse_error == null and .[0].background_subagent_running == true' "$CL"
jqcheck "非 subagent 的后台任务不算运行中" "$CL" 'select(.session_id == "claude-bg-shell" and .event == "Stop") | .background_subagent_running == false and .background_task_shapes == ["shell/running"]'
check "后台 subagent 运行/结束后两次 Stop 分别为 true/false" "$JQ" -se '[.[] | select(.session_id == "claude-bg-done" and .event == "Stop") | .background_subagent_running] == [true, false]' "$CL"
check "SessionStart 记录进程线索" "$JQ" -se '[.[] | select(.event == "SessionStart")][0].ctx.ppid | type == "number"' "$CL"
jqcheck "cursor 用 conversation_id 作会话 id、workspace_roots[0] 作 cwd" "$CU" 'select(.event == "stop") | .session_id == "cursor-conv-1" and .cwd == "/tmp/proj-d" and .status == "error"'
check "非 JSON payload 记为 parse_error" "$JQ" -se 'map(select(.parse_error)) | length == 1' "$CX"
check "非对象 payload 记为 parse_error" "$JQ" -se 'map(select(.parse_error)) | length == 1' "$CL"
check "Cursor 代执行的 Claude hook 被跳过" sh -c "! grep -q cursor-via-claude '$SPOOL/claude-code.jsonl'"
check "Devin 代执行的 Claude hook 被跳过" sh -c "! grep -q devin-via-claude '$CL'"
check "Devin shell 里启动的 Claude Code 照常记录" grep -q claude-in-devin-shell "$CL"
check "devin spool 4 行" test "$(wc -l < "$DV" | tr -d ' ')" = 4
check "devin 不含 prompt 正文 / 工具参数 / 回复" sh -c "! grep -q SECRET '$DV'"
jqcheck "devin 用 DEVIN_PROJECT_DIR 作 cwd，记录 prompt_id" "$DV" 'select(.event == "Stop") | .session_id == "devin-sess-1" and .cwd == "/tmp/proj-f" and .prompt_id == "dp-1"'
check "devin 任务开始时记录进程线索" "$JQ" -se '[.[] | select(.event == "UserPromptSubmit")][0].ctx.ppid | type == "number"' "$DV"

echo "pi 扩展"
if PW_PI_EXT="$root/pi/pitwall.ts" node --no-warnings --input-type=module -e '
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PW_PI_EXT).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { cwd: "/tmp/proj-e", sessionManager: { getSessionId: () => "pi-sess-1", getSessionFile: () => "/tmp/pi-sess-1.jsonl" } };
const calls = [
  ["session_start", { reason: "startup" }],
  ["before_agent_start", { prompt: "<ide-context file=\"a.ts\">SECRET-PI</ide-context>\n修复构建\n第二行 SECRET-PI" }],
  ["agent_start", {}],
  ["tool_execution_start", { toolName: "bash", args: { command: "echo SECRET-PI" } }],
  ["ui_prompt_start", { kind: "confirm", title: "Allow bash?" }],
  ["ui_prompt_end", {}],
  ["tool_execution_end", { toolName: "bash", result: "SECRET-PI", isError: false }],
  ["message_end", { message: { role: "assistant", stopReason: "toolUse" } }],
  ["message_end", { message: { role: "assistant", stopReason: "error", errorMessage: "provider 500",
    content: [{ type: "thinking", thinking: "SECRET-PI" }, { type: "text", text: "构建失败：\n  缺少依赖" },
              { type: "toolCall", arguments: { command: "SECRET-PI" } }] } }],
  ["agent_end", { messages: [] }],
  ["agent_settled", {}],
];
for (const [name, event] of calls) {
  if (!handlers[name]) throw new Error("missing handler " + name);
  if ((await handlers[name](event, ctx)) !== undefined) throw new Error("handler returned a value: " + name);
}
await handlers.before_agent_start({
  prompt: Array.from({length: 9}, (_, i) => `<ctx${i + 1}>SECRET-PI</ctx${i + 1}>`).join("") + "\n真正的用户请求",
}, {...ctx, sessionManager: {getSessionId: () => "pi-many-wrappers", getSessionFile: () => "/tmp/pi-many-wrappers.jsonl"}});
'; then ok "pi：handler 齐全且都不返回值"; else fail "pi：扩展运行失败"; fi
PI="$SPOOL/pi.jsonl"
check "pi spool 11 行（跳过 toolUse 的 message_end）" test "$(wc -l < "$PI" | tr -d ' ')" = 11
check "pi 不含 prompt 正文 / 工具参数 / 输出" sh -c "! grep -q SECRET '$PI'"
jqcheck "pi 记录会话 id、cwd 与失败原因" "$PI" 'select(.event == "message_end") | .session_id == "pi-sess-1" and .cwd == "/tmp/proj-e" and .stop_reason == "error"'
jqcheck "pi 回复只取文本块并压成一行" "$PI" 'select(.event == "message_end") | .reply_head == "构建失败： 缺少依赖"'
jqcheck "pi 跳过开头注入块，只记标签名" "$PI" 'select(.event == "before_agent_start" and .session_id == "pi-sess-1") | .prompt_head == "修复构建" and .prompt_wrappers == ["ide-context"]'
jqcheck "pi 超过 8 个注入块仍全部跳过，标签名仅记前 8 个" "$PI" 'select(.session_id == "pi-many-wrappers") | .prompt_head == "真正的用户请求" and .prompt_wrappers == [range(1;9) | "ctx\(.)"]'
jqcheck "pi 记录确认框标题" "$PI" 'select(.event == "ui_prompt_start") | .title == "Allow bash?"'

echo "查看工具"
"$EVENTS" status --json > "$tmp/status.jsonl"
state() { "$JQ" -r --arg a "$1" --arg s "$2" 'select(.agent == $a and .session_id == $s) | .state' "$tmp/status.jsonl"; }
check "claude 审批中 → waiting" test "$(state claude-code claude-sess-1)" = waiting
check "claude Stop 但后台 subagent 运行 → running" test "$(state claude-code claude-bg-running)" = running
check "claude 后台 subagent 结束后回 done" test "$(state claude-code claude-bg-done)" = done
check "只跑后台 shell 时 Stop → done（当前只跟踪 subagent）" test "$(state claude-code claude-bg-shell)" = done
check "codex 审批中 → waiting" test "$(state codex codex-sess-1)" = waiting
check "codex Stop → done" test "$(state codex codex-sess-2)" = done
check "cursor stop(error) → failed" test "$(state cursor cursor-conv-1)" = failed
check "pi 出错后 settled 仍为 failed" test "$(state pi pi-sess-1)" = failed
check "devin Stop → done" test "$(state devin devin-sess-1)" = done
check "status 表格可运行" "$EVENTS" status
check "tail 可运行" "$EVENTS" tail -n 5
"$EVENTS" hooks > "$tmp/hooks.txt" 2>&1 || fail "hooks 运行出错"
check "hooks：列出三处配置的 hook 数" sh -c "grep -q 'settings.json（12 个）' '$tmp/hooks.txt' && grep -q 'codex/hooks.json（7 个）' '$tmp/hooks.txt' && grep -q 'cursor/hooks.json（6 个）' '$tmp/hooks.txt'"
check "hooks：列出 pi 扩展订阅的事件" grep -q ui_prompt_start "$tmp/hooks.txt"
check "hooks：列出 devin 配置的 hook 数" grep -q 'devin/config.json（8 个）' "$tmp/hooks.txt"
check "hooks：PermissionRequest 标为等待信号" grep -q '★ PermissionRequest' "$tmp/hooks.txt"
check "hooks：提示其他来源的 hook" grep -q '另有 1 个其他来源的 hook' "$tmp/hooks.txt"
check "summary：claude/codex/pi/devin 各报告 1 次等待/审批信号" test "$("$EVENTS" summary | grep -c '等待/审批信号：1 次')" = 4
check "summary：cursor 尚未收到等待信号" sh -c "'$EVENTS' summary | grep -q '等待/审批信号：尚未收到'"

check "jump：完整会话 id 可定位" "$EVENTS" jump codex-sess-1
check "jump：未知 id 拒绝定位" sh -c '! "$1" jump missing' sh "$EVENTS"
check "jump：不接受 id 前缀" sh -c '! "$1" jump codex-sess' sh "$EVENTS"
feed cursor sessionStart '{"conversation_id":"codex-sess-1","workspace_roots":["/tmp/proj-collision"]}'
check "jump：跨 Agent 同名 id 拒绝猜测" sh -c '! "$1" jump codex-sess-1' sh "$EVENTS"
feed codex Stop '{"session_id":"","conversation_id":"","cwd":"/tmp/proj-blank","hook_event_name":"Stop"}'
check "空 session_id 不写入 spool" sh -c "! grep -q '\"session_id\":\"\"' '$SPOOL/codex.jsonl'"
# 模拟修复前写入的旧 spool：两条无关会话都带空 id
printf '%s\n' '{"v":1,"ts":1,"agent":"codex","event":"Stop","session_id":"","cwd":"/tmp/legacy-a"}' \
  '{"v":1,"ts":2,"agent":"codex","event":"Stop","session_id":"","cwd":"/tmp/legacy-b"}' >> "$SPOOL/codex.jsonl"
check "jump：拒绝空 id" sh -c '! "$1" jump ""' sh "$EVENTS"
check "jump：拒绝纯空白 id" sh -c '! "$1" jump "  "' sh "$EVENTS"
echo "异常配置"
odd="$tmp/odd-home"
mkdir -p "$odd/.claude"
printf '%s\n' '{"hooks":["unexpected-array"],"env":{"KEEP":"1"}}' > "$odd/.claude/settings.json"
odd_before=$(shasum "$odd/.claude/settings.json")
HOME="$odd" PITWALL_HOME="$odd/.pitwall" sh "$root/install.sh" install claude-code >/dev/null 2>&1 || true
check "jq 处理失败时不改写配置" test "$odd_before" = "$(shasum "$odd/.claude/settings.json")"
mkdir -p "$odd/.config/devin"
printf '%s\n' '{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"/usr/bin/true user-notify"}]}]}}' > "$odd/.config/devin/config.json"
HOME="$odd" PITWALL_HOME="$odd/.pitwall" sh "$root/install.sh" install devin > "$tmp/odd-devin.txt" 2>&1 || true
check "devin：install 警告 Devin 不认识的用户事件" grep -q '不认识的事件（Notification）' "$tmp/odd-devin.txt"
jqcheck "devin：用户的 Notification hook 不被删除" "$odd/.config/devin/config.json" '.hooks.Notification[0].hooks[0].command == "/usr/bin/true user-notify"'
HOME="$odd" PITWALL_HOME="$odd/.pitwall" "$EVENTS" doctor > "$tmp/odd-doctor.txt" 2>&1 || true
check "devin：doctor 报告 Devin 不认识的事件" grep -q '✗ devin：hooks 含 Devin 不认识的事件（Notification）' "$tmp/odd-doctor.txt"

echo "uninstall"
check "uninstall 成功" sh "$root/install.sh" uninstall
for f in .claude/settings.json .codex/hooks.json .cursor/hooks.json .config/devin/config.json; do
  seed="$tmp/seed_$(printf '%s' "$f" | tr '/.' '__')"
  check "$f 恢复为安装前内容" sh -c "'$JQ' -S . '$HOME/$f' | cmp -s - '$seed'"
done
check "pi 扩展已移除" test ! -e "$HOME/.pi/agent/extensions/pitwall.ts"
check "备份目录存在" sh -c "ls -d '$PITWALL_HOME'/backups/* >/dev/null"
check "pi 扩展不进备份（不是用户配置）" sh -c "! ls '$PITWALL_HOME'/backups/*/pi_pitwall.ts 2>/dev/null"

echo "备份保留数量"
B="$PITWALL_HOME/backups"
for i in $(seq 10 21); do mkdir -p "$B/20200101-0000$i"; done
mkdir -p "$B/keep-me" && : > "$B/notes.txt"
printf '%s\n' '{"hooks":{}}' > "$C"
sh "$root/install.sh" install claude-code >/dev/null
check "只保留最近 10 份备份" test "$(ls -1 "$B" | grep -cE '^[0-9]{8}-[0-9]{6}$')" = 10
check "最旧的备份被删除" test ! -e "$B/20200101-000010"
check "本次安装的备份保留" sh -c "ls '$B' | grep -v '^2020' | grep -qE '^[0-9]{8}-[0-9]{6}$'"
check "非备份目录与文件不被删除" sh -c "test -d '$B/keep-me' && test -f '$B/notes.txt'"

echo "损坏的配置不被覆盖"
printf '{ not json' > "$R"
sh "$root/install.sh" install cursor >/dev/null 2>&1 || true
check "非法 JSON 保持原样" test "$(cat "$R")" = "{ not json"

echo
if [ "$fails" -eq 0 ]; then echo "全部通过"; else echo "$fails 项失败"; exit 1; fi
