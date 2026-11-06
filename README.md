# Pitwall

Supervise the coding agents you already run, from the Mac menu bar. Pitwall is a local board for Codex, Claude Code, Cursor, Pi, OpenCode, Devin, Kimi Code, DeepSeek Harness and Qoder CN: see which sessions finished, failed, or need you, and jump back when it can tell which session that is. Cursor has no reliable waiting signal. No account, and what it collects stays on your Mac.

[Website](https://pitwall.oasislab.dev) · [Download](https://github.com/JasonHZS/pitwall-collector/releases/latest) · [中文](README.zh-CN.md)

## What's in this repository

| | License |
| --- | --- |
| `collector/`: the hooks, Pi extension and OpenCode plugin that record agent events on your Mac | [MIT](LICENSE) |
| `Pitwall.app` in [Releases](https://github.com/JasonHZS/pitwall-collector/releases): the menu bar app that reads those events | Proprietary, see the [terms](https://pitwall.oasislab.dev/terms.html) |

The collector is open so you can check exactly what it records, and so support for new agents can be contributed. The app is not open source.

## Install

Requires macOS 15 or later, Apple silicon.

```sh
brew install --cask jasonhzs/tap/pitwall
pitwall-collector install
```

The second command enables event collection for the agents you use; the installer is bundled in the app and backs up hook configuration before changing it. Its own Pi and OpenCode plugin files are overwritten without backup. Without arguments it sets up every supported agent; to pick some, list them, e.g. `pitwall-collector install codex claude-code`. Upgrade with `brew upgrade --cask pitwall`.

Kimi Code state collection reads its local logs and does not install a hook. Approvals and questions can show as waiting, but they cannot be answered in Pitwall, and returning to a session only opens the app. It does not use links that start a new chat.

DeepSeek Harness state collection reads its local logs without installing anything. Pitwall separately offers an optional local navigation plugin, with **Agree and Install** and **Decline** choices. Declining keeps app-only navigation and does not change the Harness profile. Settings → Agent keeps installation, repair and removal available. The plugin is bundled with Pitwall, uses Harness's own runtime offline, backs up the profile before editing, and exchanges only short-lived session IDs and navigation results over local files and Harness's existing authenticated local channel. It does not upload conversations, send prompts, answer approvals, or open a new listening port. Main-window navigation between two same-named sessions has been checked on Harness 0.2.1-rc.3 and rc.5; cross-workspace navigation has also been checked on rc.5. Cold-start navigation, notification and failure-HUD acceptance remains pending.

Plugin 1.0.3 declares only a minimum, `>=0.2.1-rc.3`, without an upper version limit. The installer and Harness loader use that same `engines.dsh` range with prereleases included. Future versions may try to run, but are not automatically considered verified. Runtime checks cover Fetch registration, navigation and snapshot methods, ready catalog/archive/panel state, target selection fields and the history reference contract before switching. Detectable incompatibility stops navigation and is reported through an optional `compatible` field in the v1 heartbeat or an `incompatible` reply; Pitwall opens Harness and explains that Pitwall needs an update. Missing dependencies that prevent plugin activation still fall back as not ready. A successful call alone never proves selection. If a main panel still covers the conversation after the session is selected, the plugin asks Harness to return to the conversation and reports success only once that panel is gone. Shape checks cannot predict every future semantic change. Older v1 heartbeats and replies remain supported. The old 1.0.0 plugin was locked to rc.3 and could be blocked on upgrade. Updating Pitwall refreshes an existing plugin without changing its profile; restart Harness to reload a previously skipped plugin. State collection is independent of this plugin version check.

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
| Devin | Devin for Terminal | Approval notifications for interactive sessions; passive status remains Unknown. Not shown as waiting | Selects the terminal tab by tty. A desktop session only opens the app |
| OpenCode | 2.x terminal TUI and `opencode run` | Permission and form prompts; permissions can be answered in Pitwall, forms in OpenCode | Switches to the Otty, Terminal or iTerm tab of the OpenCode client that has the session open, and shows it there; otherwise reopen with `opencode -s <sessionID>` |
| Kimi Code | Desktop app. Reads its own logs; no hook to install | Approvals and questions can show as waiting. Cannot be answered in Pitwall | Opens the app only. Does not use links that start a new chat |
| Qoder CN | Standalone desktop app 0.5.3; hooks in `~/.qoder-cn/settings.json` | Native questions verified. Approve / deny commands and answer questions in Pitwall for up to 60 seconds; live integration validation pending | Opens the app only; exact session navigation not verified |
| DeepSeek Harness | Desktop app. Status is read from local logs; no plugin required for status. Optional navigation plugin checked on 0.2.1-rc.3 and rc.5 | Command approvals and questions show as waiting. Answer only in Harness | After you agree, the optional plugin jumps by session ID. Otherwise it only opens the app and says why |

In-app approve or deny covers Claude Code, Codex, Devin, Pi, OpenCode and Qoder CN. Qoder CN interception awaits live validation. Cursor, Kimi Code and DeepSeek Harness approvals are not answered in Pitwall.

Jumping to the exact tab works in Terminal, iTerm2 and Otty while the original process still holds that tty. tmux only when one local client can be found. Ghostty 1.3.1 has no tty interface, so Pitwall only opens the app. Pitwall doesn't guess: when a signal isn't reliable, it doesn't claim the agent is waiting. The Homebrew `codex` command does not run on this Mac and is not supported.

## How the collector works

Claude Code, Codex, Cursor and Devin call `collector/bin/pitwall-hook` through their official hooks. Pi uses `collector/pi/pitwall.ts`; OpenCode uses the `collector/opencode/pitwall/` plugin: `server.ts` through the V2 Promise plugin API, and `tui.ts` in each terminal client to report the session it shows. Collectors keep status fields and short excerpts and append one JSON line to `~/.pitwall/events/<agent>.jsonl`. They make no network requests.

For Claude Code, the installer also registers `collector/bin/pitwall-approval` on `PermissionRequest`, so you can approve or deny a request from the Pitwall app. Claude Code shows its own dialog at the same time and the first answer applies. The hook answers only when you click Approve or Deny in Pitwall; if Pitwall isn't running it exits at once without output. While it waits, the request sits in `~/.pitwall/approvals/` on your Mac and is deleted once answered or withdrawn; tool input JSON longer than 4,000 characters is truncated for display. Terminal answers withdraw only a matching call: by call ID when available, otherwise by a unique fingerprint of the complete input. Repeated identical inputs without call IDs stay until the hook exits, the turn or session ends, or the hook times out; they are never withdrawn by tool name alone. Local fingerprint markers stay until the session ends so a late event cannot withdraw a repeated request. The request format is internal and may change between versions.

Codex also registers `pitwall-approval codex` on `PermissionRequest`. Trust the new hook in Codex `/hooks` or hook settings after reinstalling the collector. Only requests whose current rollout turn explicitly has `approvals_reviewer = "user"` are handled; auto-review and missing or unknown metadata go straight back to Codex. Codex waits for the hook before showing its own dialog: approve or deny in Pitwall, or approve on the notification banner, within 60 seconds. If unanswered, or Pitwall stops listening, the hook exits without a decision and Codex continues its normal approval flow. Requests are isolated by agent, session and turn; interrupted or finished turns withdraw only their own requests. The hook reads at most the last 1 MiB of the rollout to identify the reviewer and retains no rollout content. Approval request files temporarily contain display input as described above; the event spool still omits Codex tool inputs.

Devin also registers `pitwall-approval devin` on `PermissionRequest`. Like Codex, Devin shows its own dialog only after the hook returns: approve or deny in Pitwall, or approve on the notification banner, within 60 seconds; otherwise the hook exits without a decision and Devin's dialog appears. Print mode (`devin -p`) has nobody to answer, so it goes straight back to Devin. Devin's payload has no working directory, so the request records `DEVIN_PROJECT_DIR`. `Stop` withdraws only its own prompt's requests and `SessionEnd` clears the session's.

Pi has no approval hook; its prompts come from other extensions, such as command guards. While Pitwall listens, the Pi extension hands allow / reject prompts raised during an agent run to Pitwall. The terminal prompt stays open and the first answer applies. OpenCode's V2 plugin similarly forwards permission requests while OpenCode's own prompt stays open; Pitwall's `allow` maps to a one-time approval and `deny` to rejection. Forms are visible as waiting status but must be answered in OpenCode. The server plugin can't see terminals; `tui.ts` reports which session each terminal client shows, so Pitwall can return to it.

**Questions.** When an agent asks you something, Pitwall shows the questions and options as a form; send it once every question is answered. Requests carry `answer_format: "answers-v1"`; a collector without it falls back to answering in the agent. Question input is kept whole instead of truncated, and nothing is sent back unless every question has a non-empty answer.

- Claude Code `AskUserQuestion` (on `PermissionRequest`): the terminal shows its own question at the same time and the first answer applies. Pitwall's answers come back as `updatedInput.answers`.
- Codex `request_user_input` and Devin `ask_user_question`: the installer adds `pitwall-approval` on `PreToolUse`, matched to that tool only. Both wait for the hook before showing their own question, so answer within 60 seconds; otherwise it appears as usual. These tools take no answers in their input, so the hook blocks the call and puts your answers in the reason the model reads; the terminal shows the call as rejected, followed by your answers. Trust the new hook in Codex after reinstalling.
- Qoder CN `AskUserQuestion`: an exact-match `PreToolUse` hook waits up to 60 seconds, then blocks the call with your answers in the reason the model reads. Command permissions use `PermissionRequest` allow / deny. Reinstall or repair the hooks and start a new task; live desktop validation is pending.
- Codex Desktop asks with `request_user_input_async`, which returns at once while the agent keeps working, so Pitwall doesn't hold it: the session shows as waiting, with the first question's first line, until you answer in Codex.
- Pi: plain select prompts (options only) and text input prompts raised during an agent run race the terminal like approvals. Pi's example `question` / `questionnaire` tools draw their own UI, so `tool_call` hands their questions to Pitwall first for up to 60 seconds and, once answered, blocks the call with your answers as the reason; otherwise the tool's UI appears as usual.
- Cursor and Kimi Code are not supported: Cursor's question tool has not been verified with hooks, and Kimi Code's hooks do not wait for an answer.

Cursor isn't supported: it has no hook that fires only when it asks you, and its `before*` hooks run for every proposed command.

**Recorded:** event name, time, session and turn IDs, working directory, transcript path, tool name, status and stop reason, a truncated error, the first line of the prompt (up to 80 characters), and terminal hints (tty, `TERM_PROGRAM`, tmux pane and local socket path) used to jump back to the session. For Claude Code, Pi, OpenCode and Qoder CN: the first line of a pending approval (up to 120 characters) and the first 160 characters of the final reply; for Codex Desktop, the first line of an async question's first title (up to 120 characters) and the IDs of the questions each answer covers. These let the board show what the agent is waiting on and how it finished.

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

The Harness plugin can be uninstalled even if the desktop app or profile is missing. Its local files and navigation marker are removed; an invalid profile is kept unchanged, with remaining entries shown for cleanup retry in Settings. Uninstall the navigation plugin and resolve any remaining profile entries before deleting `~/.pitwall/`.

Hook backups in `~/.pitwall/backups/<date>-<time>/` and Harness profile backups in `~/.pitwall/backups/deepseek-<milliseconds>-<random>/` are independent: each installer keeps its own latest 10 groups (normally up to 20 combined). The latter copies `package.json` and `cordis.patch.yml`, which may contain sensitive settings.

`sh collector/tests/run.sh` automatically includes the real Harness YAML installer tests when `/Applications/DeepSeek Harness.app` provides a runtime inside the plugin's `engines.dsh` range. Set `PITWALL_DSH_APP` to a different `.app` location if needed; without that runtime or with an unsupported version, the runner explicitly reports skipped installer tests and still runs the Node protocol tests. All installer fixtures use temporary directories.

## Qoder CN

Install with `sh collector/install.sh install qoder-cn`; remove with `sh collector/install.sh uninstall qoder-cn`. The installer backs up settings before edits, preserves other hooks, and can run repeatedly without changing an up-to-date configuration. Start a new task after installation; restart Qoder CN if its runtime has not loaded the hooks. Events stay in `~/.pitwall/events/qoder-cn.jsonl`.

Verified with standalone Qoder CN 0.5.3: start, final completion, user interruption, native questions and a foreground subagent. `Stop` is a reply preview; `QueryEnd` supplies the final result. A native `permission_prompt` notification identifies the tool call being waited on, so another parallel tool finishing does not clear the wait. The installer also adds synchronous approval and question hooks. Answer in Pitwall within 60 seconds; otherwise the hook returns without a decision and Qoder continues its native flow. No active listener, unsupported questions and invalid decisions also return to Qoder. Subagent requests are not intercepted. Tool approvals, interception and fatal errors still need live validation. IDE, CLI and international Qoder are not covered by this verification.

The collector stores request / waiting / reply excerpts capped at 80 / 120 / 160 characters, plus identifiers and status metadata. It does not copy complete tool payloads or approval files into events, and the app does not read Qoder CN project conversation files. Pending approval inputs (display JSON capped at 4,000 characters), complete question forms and answers temporarily live in `~/.pitwall/approvals/` and are removed after handling, withdrawal or timeout; fingerprint markers remain until session end. Answers are passed to the model, which may repeat them in its reply; those words can then be saved in event reply excerpts and app task history. Removing approval files does not remove those excerpts. Existing observation-only installations need a repair or reinstall to add the two decision hooks.
