# Event format, version 1

The collector writes one file per agent, `~/.pitwall/events/<agent>.jsonl` (or `$PITWALL_HOME/events/` when set). Each line is one JSON object describing one event the agent reported. Files are append-only: a line is never rewritten or removed by the collector.

This file format is the only public interface between the collector and anything that reads it. Other files under `~/.pitwall/` and any other channel between the collector and the Pitwall app are internal and can change without notice.

## Compatibility

- Every record carries `v`. Additive changes (a new field, a new agent, a new event name) keep `v: 1`. Removing a field or changing its meaning bumps `v`, and readers are expected to support the previous version for a while.
- Readers must ignore fields they don't know.
- A field is omitted when the agent didn't provide it, or when it would be empty. `null` and `{}` are never written.
- Strings marked "truncated" keep the first N characters and end with `…` when they were longer.

## Delivery

- `ts` is when the collector observed the event (milliseconds since the Unix epoch, local clock), not a time reported by the agent.
- Records are written in the order the agent ran its hooks, but an agent may run hooks concurrently, so readers shouldn't rely on strict ordering within a few milliseconds.
- An event can be missing: an agent may skip a hook (for example when a window is closed), and a hook that fails never retries. Readers should treat the absence of an event as "unknown", never as a result.
- A payload the collector can't parse still produces a record with `parse_error: true` and only `v`, `ts`, `agent` and `event`.

## Fields

### Always present

| Field | Type | Meaning |
| --- | --- | --- |
| `v` | number | Format version, `1` |
| `ts` | number | Observation time, milliseconds since the Unix epoch |
| `agent` | string | `claude-code`, `codex`, `cursor`, `pi` or `devin`; new agents add new values |
| `event` | string | The agent's own event name, unchanged (see [Events by agent](#events-by-agent)) |

### Identity and location

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | The agent's session (or conversation) ID |
| `turn_id` | string | The agent's ID for the current turn or generation, when it has one |
| `prompt_id` | string | Claude Code: ID of the current request; follow-up input in the same turn keeps it. Truncated to 80 |
| `agent_id`, `agent_type` | string | Claude Code: set on events from a subagent. Truncated to 80 and 60 |
| `cwd` | string | Working directory of the session (Devin: its project directory) |
| `workspace_roots` | array of strings | Cursor: the workspace folders |
| `transcript_path` | string | Path of the agent's own transcript or session file |
| `model`, `permission_mode`, `source` | string | As reported by the agent |

### Status

| Field | Type | Meaning |
| --- | --- | --- |
| `tool_name` | string | Tool the event is about |
| `notification_type` | string | Claude Code `Notification`: for example `permission_prompt` |
| `status` | string | Status reported by the agent. Truncated to 40 |
| `stop_reason` | string | Pi `message_end`: `stop`, `error` or `aborted` |
| `error` | string | Error message. Truncated to 200 |
| `is_error` | boolean | Pi `tool_execution_end`: the tool failed |
| `is_interrupt` | boolean | Claude Code `PostToolUseFailure`: the user interrupted the tool |
| `kind` | string | Pi `ui_prompt_start`: `confirm`, `select`, `input` and so on |
| `title` | string | Title of a prompt or notification. Truncated to 120 |
| `message` | string | Notification text. Truncated to 160 |
| `reason` | string | Why a session started or ended. Truncated to 120 |
| `stop_hook_active` | boolean | Claude Code `Stop`: the turn continues because of a stop hook |
| `background_subagent_running` | boolean | Claude Code `Stop`: a background subagent was still running |
| `background_task_shapes` | array of strings | Claude Code `Stop`: distinct `type/status` pairs of background tasks, at most 8; values outside `[A-Za-z0-9_.-]{1,40}` become `?` |

### Short excerpts

These exist so a board can show what a session is about, what it is waiting on and how it ended.

| Field | Type | Meaning |
| --- | --- | --- |
| `prompt_head` | string | First non-empty line of the request, truncated to 80. Blocks a client wraps around the request at its start (`<tag …>…</tag>`) are skipped first |
| `prompt_wrappers` | array of strings | Names of the skipped wrapper tags, at most 8; the contents are not recorded |
| `tool_summary` | string | Claude Code `PermissionRequest`: first non-empty line of the command, file path or URL being approved, truncated to 120 |
| `reply_head` | string | Claude Code `Stop` and Pi `message_end`: the final reply squashed to one line, truncated to 160 |

Nothing else from the request, tool inputs, tool outputs, replies or thinking is recorded. The excerpts above, paths and error text can still contain sensitive information: truncating isn't redacting. Files are never rotated or expired; uninstalling the collector or clearing Pitwall's history leaves them in place.

### Diagnostics

| Field | Type | Meaning |
| --- | --- | --- |
| `payload_keys` | array of strings | Names of the top-level fields in the agent's payload (not their values), to notice when an agent changes its payload |
| `parse_error` | boolean | The payload could not be parsed |

### Terminal hints: `ctx`

Recorded at session start and at the start of each request, to find the terminal tab the session runs in. Only names and identifiers, never environment values other than those listed.

| Field | Meaning |
| --- | --- |
| `ppid`, `pid` | Process IDs (Pi records its own `pid`) |
| `proc`, `parent_proc` | `{pid, ppid, tty, comm}` of the agent process and its parent |
| `term_program` | `TERM_PROGRAM` |
| `term_session_id`, `iterm_session_id` | `TERM_SESSION_ID`, `ITERM_SESSION_ID` |
| `tmux_pane` | `TMUX_PANE` |
| `bundle_id` | `__CFBundleIdentifier` of the app that launched the agent |
| `ghostty_env` | Names (not values) of `GHOSTTY_*` variables |

## Events by agent

`event` is the agent's own name, so the set differs per agent. A reader decides what each name means for that agent.

| Agent | Source | Events |
| --- | --- | --- |
| `claude-code` | Hooks in `~/.claude/settings.json` | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`, `Notification`, `Elicitation`, `Stop`, `StopFailure` |
| `codex` | Hooks in `~/.codex/hooks.json` | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` |
| `cursor` | Hooks in `~/.cursor/hooks.json` | `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `postToolUse`, `postToolUseFailure`, `stop` |
| `devin` | Hooks in `~/.config/devin/config.json` | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `PostCompaction` |
| `pi` | Extension in `~/.pi/agent/extensions/pitwall.ts` | `session_start`, `session_shutdown`, `before_agent_start`, `agent_start`, `tool_execution_start`, `tool_execution_end`, `ui_prompt_start`, `ui_prompt_end`, `message_end` (only when a turn ends: `stop`, `error`, `aborted`), `agent_end`, `agent_settled` |

An event name alone is not always a reliable signal. For example, a permission request can be answered automatically by the agent without anyone waiting, and some agents skip their stop hook when a request fails. Readers should combine events, and fall back to "unknown" when they can't tell.

## Example

```json
{"v":1,"ts":1760140800123,"agent":"claude-code","event":"UserPromptSubmit","session_id":"3f6c2a1e-…","prompt_id":"b81d…","cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl","prompt_head":"Fix the failing date parser test","payload_keys":["cwd","hook_event_name","prompt","prompt_id","session_id","transcript_path"],"ctx":{"ppid":48211,"proc":{"pid":"48211","ppid":"48190","tty":"ttys004","comm":"claude"},"term_program":"iTerm.app"}}
```
