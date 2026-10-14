# Contributing

Thanks for helping. This repository holds the collector: the hooks and the Pi extension that record coding agent events on the user's Mac. The most useful contribution is support for another agent. Fixes for the existing agents, the installer and the debug tool are welcome too.

Before writing code for a new agent, open an issue with:

- the agent, the forms you use it in (CLI, desktop app, IDE) and their versions;
- how it lets outside programs observe it: hooks, an extension API, or files it writes;
- which events mark that a request started, that the agent waits for you, and that the request finished, failed or was cancelled, and how sure you are about each.

We'll agree on the approach there, so your work doesn't go to waste.

## What the Pitwall app does with it

Pitwall reads the event files described in [docs/event-format.md](docs/event-format.md). The app isn't open source, and it shows an agent only once it knows how to read that agent's events. When a new agent lands in the collector, the maintainer adds it to the app. Your sample events in the pull request are what make that possible.

## Rules every change follows

These are the promises users rely on when they let the collector into their agent configs.

**Observe, never interfere.**
- An event hook never writes to stdout and always exits 0. It must not approve, deny, block, delay or change anything the agent does, and must not add text to the agent's context. The one exception is `pitwall-approval`, which answers a permission request only after the user clicks Approve or Deny in Pitwall.
- Register a hook as asynchronous when the agent supports it. When it doesn't, keep the hook fast and give it a short timeout.
- Don't register hooks whose output the agent treats as a decision (for example "before running a shell command" hooks that can veto the command).
- An extension handler returns nothing and swallows its own errors.

**Record as little as possible.**
- Map the payload to the fields in [docs/event-format.md](docs/event-format.md) with an allowlist. Never copy the payload through.
- Never record tool inputs or outputs, replies, thinking, transcript contents or account details. The only excerpts are the ones the format defines (first line of the request, and so on), with the same truncation.
- Add a new field only when the app needs it, and describe it in the format document in the same pull request.
- No network requests, ever.

**Change the user's configs safely.**
- The installer is idempotent: running `install` twice leaves the config unchanged, and entries that are already correct keep their position.
- It only adds or removes entries whose command contains `pitwall-hook`. Every other hook and setting stays as it was.
- It backs up a config before changing it, and refuses to touch a file that isn't valid JSON.
- `uninstall` removes exactly what `install` added.

**Keep it portable.**
- POSIX `sh`, and only commands that ship with macOS, called by absolute path (`/usr/bin/jq`, `/bin/ps`). Agents launched from desktop apps run hooks with a minimal `PATH`.
- Target macOS 15 and later.

## Adding an agent

1. **`collector/install.sh`**: add the agent's config path, the list of events to register, and `install_<agent>` / `uninstall_<agent>` functions modeled on the existing ones. Use the nested or flat helpers depending on how the agent structures its hooks. Add the agent to the usage text and the default list.
2. **`collector/bin/pitwall-hook`**: the hook is called as `pitwall-hook <agent> <event>` with the payload on stdin. Map the agent's field names to the shared ones (`session_id`, `turn_id`, `cwd`, …) in the jq filter. If the agent also runs another agent's hooks (some read `~/.claude/settings.json`), detect that and skip the duplicate.
3. **`collector/bin/pitwall-events`**: add the agent to `doctor` so it checks the number of registered hooks.
4. **`collector/tests/run.sh`**: cover installing into a config that already has the user's own hooks, reinstalling without changes, recording a sample payload with the expected fields (and without the ones that must not be recorded), and uninstalling back to the original config.
5. **`docs/event-format.md`**: add the agent to "Events by agent", and document any new field.
6. **`README.md`** and **`README.zh-CN.md`**: add the agent to the install command and the supported agents table.

An agent with an extension API instead of hooks (like Pi) gets its own extension file under `collector/<agent>/`, writing the same format.

## Testing

```sh
sh collector/tests/run.sh
```

The tests run in a temporary home directory and never touch your real configs. To try a change on your own agents:

```sh
sh collector/install.sh install <agent>
~/.pitwall/bin/pitwall-events tail -f
```

Then use the agent normally: start a request, let it finish, make one fail, cancel one, and trigger an approval if the agent has them. `~/.pitwall/bin/pitwall-events summary` lists which events arrived and whether any waiting signal showed up. `sh collector/install.sh uninstall <agent>` removes Pitwall's hooks or extension from the current configuration, leaving event files and backups in place.

## Pull requests

Include:

- the agent versions and macOS version you tested with;
- the sequences of events you observed for a successful request, a failed one, a cancelled one and, if the agent has them, an approval. Paste the lines from `pitwall-events tail` after replacing paths, prompts, session IDs and anything else personal with placeholders;
- what you couldn't verify.

Keep each pull request to one agent or one fix. Comments in the scripts explain why, not what.

By submitting a contribution you agree that it's licensed under the [MIT License](LICENSE) of this repository.

## Reporting a security or privacy issue

If the collector records something it shouldn't, or could be made to interfere with an agent, please don't open a public issue. Use GitHub's private vulnerability reporting on this repository instead.
