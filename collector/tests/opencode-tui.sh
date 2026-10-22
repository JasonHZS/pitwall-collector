#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-opencode-tui.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PITWALL_HOME="$tmp/pitwall" TERM_PROGRAM=otty PW_OPENCODE_TUI="$root/opencode/pitwall/tui.ts" node --no-warnings --input-type=module -e '
import { pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const home = process.env.PITWALL_HOME;
const clientFile = join(home, "opencode", "clients", `${process.pid}.json`);
const focusDir = join(home, "opencode", "focus");
const focusFile = join(focusDir, String(process.pid));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (name, ok) => checks.push([name, !!ok]);
const read = () => existsSync(clientFile) ? JSON.parse(readFileSync(clientFile, "utf8")) : undefined;

// A fake TUI: one root with a subagent child, tabs on, and calls recorded.
let route = { type: "session", sessionID: "ses_child" };
let tabsOn = true;
const tabs = [{ sessionID: "ses_root", active: true }, { sessionID: "ses_other", active: false }];
const calls = [];
const ctx = {
  location: { directory: "/repo" },
  data: { session: { root: (id) => id === "ses_child" ? "ses_root" : id } },
  ui: {
    router: {
      current: () => route,
      navigate: (destination) => { calls.push(["navigate", destination.sessionID]); route = destination; },
    },
    tabs: {
      enabled: () => tabsOn,
      list: () => tabs,
      focus: (id) => { calls.push(["focus", id]); route = { type: "session", sessionID: id }; return true; },
    },
  },
};
// A request left behind by an earlier process with this pid.
mkdirSync(focusDir, { recursive: true });
writeFileSync(focusFile, "ses_other");
const mod = await import(pathToFileURL(process.env.PW_OPENCODE_TUI).href);
const cleanup = await mod.default.setup(ctx);
check("a request left for an earlier process with this pid is dropped at startup",
  !existsSync(focusFile) && calls.length === 0);
let client = read();
check("client file names this process, its terminal and start time",
  client?.pid === process.pid && client.terminal === "otty" && client.cwd === "/repo" &&
  Math.abs(client.started - (Date.now() - process.uptime() * 1000)) < 2000);
check("a subagent view and tabs are reported as root sessions",
  client?.current === "ses_root" && client.tabs.join("|") === "ses_root|ses_other");

mkdirSync(focusDir, { recursive: true });
writeFileSync(focusFile, "ses_other");
await sleep(700);
client = read();
check("a focus request switches tabs, is consumed and the new session is published",
  calls.some(([kind, id]) => kind === "focus" && id === "ses_other") && !existsSync(focusFile) && client?.current === "ses_other");

tabsOn = false;
writeFileSync(focusFile, "ses_root");
await sleep(700);
check("without tabs the client navigates to the session",
  calls.some(([kind, id]) => kind === "navigate" && id === "ses_root") && read()?.current === "ses_root" && read()?.tabs.length === 0);

const before = calls.length;
writeFileSync(focusFile, "../escape");
await sleep(700);
check("an unsafe session id is dropped without navigating", calls.length === before && !existsSync(focusFile));

route = { type: "home" };
await sleep(700);
check("the home screen publishes no current session", read()?.current === null);

await cleanup();
check("cleanup removes the client file", !existsSync(clientFile));

for (const [name, ok] of checks) console.log(`  ${ok ? "ok  " : "FAIL"} ${name}`);
if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
'
