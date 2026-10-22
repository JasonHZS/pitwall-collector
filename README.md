# Pitwall

The pit wall for your coding agents. Pitwall is a local macOS board for Codex, Claude Code, Cursor, Pi, Devin and OpenCode: see what every session is doing, get notified the moment one needs you, and jump back to its session in a click. No account, and what it collects stays on your Mac.

[Website](https://pitwall.oasislab.dev) · [Download](https://github.com/JasonHZS/pitwall-collector/releases/latest) · [中文](README.zh-CN.md)

## What's in this repository

| | License |
| --- | --- |
| `collector/`: the hooks, Pi extension and OpenCode plugin that record agent events on your Mac | [MIT](LICENSE) |
| `Pitwall.app` in [Releases](https://github.com/JasonHZS/pitwall-collector/releases): the menu bar app that reads those events | Proprietary, see the [terms](https://pitwall.oasislab.dev/terms.html) |

The collector is open so you can check exactly what it records, and so support for new agents can be contributed. The app is not open source.

## Install

Requires macOS 15 or later.

```sh
brew install --cask jasonhzs/tap/pitwall
pitwall-collector install
```

The second command enables event collection for the agents you use; the installer is bundled in the app and backs up hook configuration before changing it. Its own Pi and OpenCode plugin files are overwritten without backup. Without arguments it sets up every supported agent; to pick some, list them, e.g. `pitwall-collector install codex claude-code`. Upgrade with `brew upgrade --cask pitwall`.

Or download `Pitwall.dmg` from [Releases](https://github.com/JasonHZS/pitwall-collector/releases/latest) and drag Pitwall to Applications. Without Homebrew there is no `pitwall-collector` command; run the bundled installer by its path instead (Pitwall's Settings lists the command for each agent):

```sh
sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh install
```

To work from this repository, run `sh collector/install.sh install`.

**Codex asks you to trust new hooks once.** Open the Codex CLI, type `/hooks` and trust the pitwall hooks. New agent sessions pick up the hooks; in an open Pi session, run `/reload`. OpenCode watches its plugin directory and picks up the Pitwall plugin automatically.

To remove Pitwall's hooks and plugins again (event files and backups stay):

```sh
pitwall-collector uninstall   # or, with the DMG: sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh uninstall
```

## Supported agents

| Agent | Tested with | Notified when it waits for you | Jump back to the session |
| --- | --- | --- | --- |
| Claude Code | CLI and the Claude desktop app | Yes | Desktop session, or the terminal tab |
| Codex | Desktop app, built-in CLI, Chrome extension | Approval notifications for user-reviewed requests; passive status remains Unknown | Desktop session, or the terminal tab |
| Cursor | IDE and background agents | No reliable signal; approving from Pitwall isn't supported | Opens Cursor |
| Pi | Terminal | Yes, when an extension asks for input; allow / reject prompts can be answered from Pitwall | Terminal tab |
| Devin | Devin for Terminal | Approval notifications for interactive sessions; passive status remains Unknown | Terminal tab |
| OpenCode | 2.x terminal TUI and `opencode run` | Permission and form prompts; permissions can be answered in Pitwall, forms in OpenCode | Switches to the Otty, Terminal or iTerm tab of the OpenCode client that has the session open, and shows it there; otherwise reopen with `opencode -s <sessionID>` |

Jumping to the exact tab works in Terminal, iTerm2 and Otty. Pitwall doesn't guess: when a signal isn't reliable, it doesn't claim the agent is waiting.

## How the collector works

Claude Code, Codex, Cursor and Devin call `collector/bin/pitwall-hook` through their official hooks. Pi uses `collector/pi/pitwall.ts`; OpenCode uses the `collector/opencode/pitwall/` plugin: `server.ts` through the V2 Promise plugin API, and `tui.ts` in each terminal client to report the session it shows. Collectors keep status fields and short excerpts and append one JSON line to `~/.pitwall/events/<agent>.jsonl`. They make no network requests.

For Claude Code, the installer also registers `collector/bin/pitwall-approval` on `PermissionRequest`, so you can approve or deny a request from the Pitwall app. Claude Code shows its own dialog at the same time and the first answer applies. The hook answers only when you click Approve or Deny in Pitwall; if Pitwall isn't running it exits at once without output. While it waits, the request sits in `~/.pitwall/approvals/` on your Mac and is deleted once answered or withdrawn; tool input JSON longer than 4,000 characters is truncated for display. Terminal answers withdraw only a matching call: by call ID when available, otherwise by a unique fingerprint of the complete input. Repeated identical inputs without call IDs stay until the hook exits, the turn or session ends, or the hook times out; they are never withdrawn by tool name alone. Local fingerprint markers stay until the session ends so a late event cannot withdraw a repeated request. The request format is internal and may change between versions.

Codex also registers `pitwall-approval codex` on `PermissionRequest`. Trust the new hook in Codex `/hooks` or hook settings after reinstalling the collector. Only requests whose current rollout turn explicitly has `approvals_reviewer = "user"` are handled; auto-review and missing or unknown metadata go straight back to Codex. Codex waits for the hook before showing its own dialog: approve or deny in Pitwall, or approve on the notification banner, within 60 seconds. If unanswered, or Pitwall stops listening, the hook exits without a decision and Codex continues its normal approval flow. Requests are isolated by agent, session and turn; interrupted or finished turns withdraw only their own requests. The hook reads at most the last 1 MiB of the rollout to identify the reviewer and retains no rollout content. Approval request files temporarily contain display input as described above; the event spool still omits Codex tool inputs.

Devin also registers `pitwall-approval devin` on `PermissionRequest`. Like Codex, Devin shows its own dialog only after the hook returns: approve or deny in Pitwall, or approve on the notification banner, within 60 seconds; otherwise the hook exits without a decision and Devin's dialog appears. Print mode (`devin -p`) has nobody to answer, so it goes straight back to Devin. Devin's payload has no working directory, so the request records `DEVIN_PROJECT_DIR`. `Stop` withdraws only its own prompt's requests and `SessionEnd` clears the session's.

Pi has no approval hook; its prompts come from other extensions, such as command guards. While Pitwall listens, the Pi extension hands allow / reject prompts raised during an agent run to Pitwall. The terminal prompt stays open and the first answer applies. OpenCode's V2 plugin similarly forwards permission requests while OpenCode's own prompt stays open; Pitwall's `allow` maps to a one-time approval and `deny` to rejection. Forms are visible as waiting status but must be answered in OpenCode. The server plugin can't see terminals; `tui.ts` reports which session each terminal client shows, so Pitwall can return to it.

**Questions.** When an agent asks you something, Pitwall shows the questions and options as a form; send it once every question is answered. Requests carry `answer_format: "answers-v1"`; a collector without it falls back to answering in the agent. Question input is kept whole instead of truncated, and nothing is sent back unless every question has a non-empty answer.

- Claude Code `AskUserQuestion` (on `PermissionRequest`): the terminal shows its own question at the same time and the first answer applies. Pitwall's answers come back as `updatedInput.answers`.
- Codex `request_user_input` and Devin `ask_user_question`: the installer adds `pitwall-approval` on `PreToolUse`, matched to that tool only. Both wait for the hook before showing their own question, so answer within 60 seconds; otherwise it appears as usual. These tools take no answers in their input, so the hook blocks the call and puts your answers in the reason the model reads; the terminal shows the call as rejected, followed by your answers. Trust the new hook in Codex after reinstalling.
- Pi: plain select prompts (options only) and text input prompts raised during an agent run race the terminal like approvals. Pi's example `question` / `questionnaire` tools draw their own UI, so `tool_call` hands their questions to Pitwall first for up to 60 seconds and, once answered, blocks the call with your answers as the reason; otherwise the tool's UI appears as usual.
- Cursor and Kimi Code are not supported: Cursor's question tool has not been verified with hooks, and Kimi Code's hooks do not wait for an answer.

Cursor isn't supported: it has no hook that fires only when it asks you, and its `before*` hooks run for every proposed command.

**Recorded:** event name, time, session and turn IDs, working directory, transcript path, tool name, status and stop reason, a truncated error, the first line of the prompt (up to 80 characters), and terminal hints (tty, `TERM_PROGRAM`) used to jump back to the session. For Claude Code, Pi and OpenCode: the first line of a pending approval (up to 120 characters) and the first 160 characters of the final reply, so the board can show what the agent is waiting on and how it finished.

**Not recorded:** the rest of the prompt, tool inputs and outputs, replies beyond the excerpt above, thinking and transcript contents. Excerpts and paths can still contain sensitive text, since truncating isn't redacting.

Event files grow until you delete them. The installer backs up hook configuration before changing it (backups can contain sensitive settings); its own Pi and OpenCode plugin files are overwritten without backup. Uninstalling removes Pitwall's entries rather than restoring a backup, and leaves event files and backups in place. Details are in the [Privacy Policy](https://pitwall.oasislab.dev/privacy.html).

To see what has been recorded:

```sh
~/.pitwall/bin/pitwall-events tail -f
```

Other commands: `status`, `summary`, `hooks` (what is registered in each agent and what the script records) and `doctor` (checks registration, Codex trust and the latest event per agent). Every field is documented in [docs/event-format.md](docs/event-format.md).

## Adding an agent

Support for a new agent starts in the collector. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and open an issue before starting so we can agree on which events mean "started", "waiting" and "finished" for that agent.

## Feedback

Bug reports and agent requests go to [Issues](https://github.com/JasonHZS/pitwall-collector/issues). Settings → "Copy diagnostics" in the app copies versions, source health, counts and settings to the clipboard. Review it before posting: issues are public.

## License

The code in this repository is licensed under [MIT](LICENSE). The Pitwall name and icon, and the app binaries in Releases, are not covered by it.
