# Pitwall

The pit wall for your coding agents. Pitwall is a local macOS board for Codex, Claude Code, Cursor, Pi and Devin: see what every session is doing, get notified the moment one needs you, and jump back to its session in a click. No account, and what it collects stays on your Mac.

[Website](https://pitwall.oasislab.dev) · [Download](https://github.com/JasonHZS/pitwall-collector/releases/latest) · [中文](README.zh-CN.md)

## What's in this repository

| | License |
| --- | --- |
| `collector/`: the hooks and the Pi extension that record agent events on your Mac | [MIT](LICENSE) |
| `Pitwall.app` in [Releases](https://github.com/JasonHZS/pitwall-collector/releases): the menu bar app that reads those events | Proprietary, see the [terms](https://pitwall.oasislab.dev/terms.html) |

The collector is open so you can check exactly what it records, and so support for new agents can be contributed. The app is not open source.

## Install

Requires macOS 15 or later.

Download `Pitwall.dmg` from [Releases](https://github.com/JasonHZS/pitwall-collector/releases/latest), open it and drag Pitwall to Applications.

Then enable event collection for the agents you use. The installer is bundled in the app and backs up each agent's config before changing it:

```sh
sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh install
```

Without arguments it sets up every supported agent; to pick some, list them, e.g. `install codex claude-code`. Pitwall's Settings lists the command for each agent, ready to copy. To work from this repository, run `sh collector/install.sh install`.

**Codex asks you to trust new hooks once.** Open the Codex CLI, type `/hooks` and trust the pitwall hooks. New agent sessions pick up the hooks; in an open Pi session, run `/reload`.

To remove Pitwall's hooks and extension again (event files and backups stay):

```sh
sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh uninstall
```

## Supported agents

| Agent | Tested with | Notified when it waits for you | Jump back to the session |
| --- | --- | --- | --- |
| Claude Code | CLI and the Claude desktop app | Yes | Desktop session, or the terminal tab |
| Codex | Desktop app, built-in CLI, Chrome extension | No reliable signal yet | Desktop session, or the terminal tab |
| Cursor | IDE and background agents | No reliable signal | Opens Cursor |
| Pi | Terminal | Yes, when an extension asks for input | Terminal tab |
| Devin | Devin for Terminal | No reliable signal yet | Terminal tab |

Jumping to the exact tab works in Terminal, iTerm2 and Otty. Pitwall doesn't guess: when a signal isn't reliable, it doesn't claim the agent is waiting.

## How the collector works

Each agent calls `collector/bin/pitwall-hook` through its official hooks (Pi uses `collector/pi/pitwall.ts` through its extension API). The hook keeps status fields and short excerpts and appends one JSON line to `~/.pitwall/events/<agent>.jsonl`. It never writes to stdout and always exits 0, so it can't approve or deny anything, block a prompt or add to the agent's context. It makes no network requests.

**Recorded:** event name, time, session and turn IDs, working directory, transcript path, tool name, status and stop reason, a truncated error, the first line of the prompt (up to 80 characters), and terminal hints (tty, `TERM_PROGRAM`) used to jump back to the session. For Claude Code and Pi only: the first line of a pending approval (up to 120 characters) and the first 160 characters of the final reply, so the board can show what the agent is waiting on and how it finished.

**Not recorded:** the rest of the prompt, tool inputs and outputs, replies beyond the excerpt above, thinking and transcript contents. Excerpts and paths can still contain sensitive text, since truncating isn't redacting.

Event files grow until you delete them. The installer backs up each config file before changing it (backups can contain sensitive settings); uninstalling removes Pitwall's entries rather than restoring a backup, and leaves event files and backups in place. Details are in the [Privacy Policy](https://pitwall.oasislab.dev/privacy.html).

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
