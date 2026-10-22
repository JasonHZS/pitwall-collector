#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-opencode-plugin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PITWALL_HOME="$tmp/pitwall" PW_OPENCODE_PLUGIN="$root/opencode/pitwall/server.ts" node --no-warnings --input-type=module -e '
import { pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const home = process.env.PITWALL_HOME;
const approvals = join(home, "approvals");
const requests = join(approvals, "requests");
const decisions = join(approvals, "decisions");
const spool = join(home, "events", "opencode.jsonl");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const checks = [];
const check = (name, ok) => checks.push([name, !!ok]);
function bus() {
  const feeds = new Map();
  const deliveries = [];
  return {
    subscribe({ signal }, label) {
      const queue = [];
      const waiters = [];
      let closed = false;
      const push = (value) => {
        if (closed) return;
        const waiter = waiters.shift();
        if (waiter) waiter({ value, done: false });
        else queue.push(value);
      };
      const close = () => {
        closed = true;
        feeds.delete(push);
        for (const waiter of waiters.splice(0)) waiter({ done: true });
      };
      feeds.set(push, label);
      signal.addEventListener("abort", close, { once: true });
      return {
        [Symbol.asyncIterator]() { return this; },
        next() { return queue.length ? Promise.resolve({ value: queue.shift(), done: false })
          : closed ? Promise.resolve({ done: true }) : new Promise((resolve) => waiters.push(resolve)); },
        return() { close(); return Promise.resolve({ done: true }); },
      };
    },
    send(event, reverse = false) {
      const subscribers = [...feeds.entries()];
      if (reverse) subscribers.reverse();
      for (const [feed, label] of subscribers) {
        deliveries.push({ id: event.id, label });
        feed(event);
      }
    },
    deliveries,
    get subscribers() { return feeds.size; },
  };
}
const events = bus();
const replies = [];
const lookups = [];
// Sessions whose lookup is shaped by a test: parent, a number of misses before it is found, a delay.
const tree = new Map();
const misses = new Map();
const delays = new Map();
const makeContext = (label, directory) => ({
  location: { directory },
  event: { subscribe: (options) => events.subscribe(options, label) },
  session: { get: async ({ sessionID }) => {
    lookups.push({ label, sessionID });
    if (delays.has(sessionID)) await sleep(delays.get(sessionID));
    if ((misses.get(sessionID) ?? 0) > 0) {
      misses.set(sessionID, misses.get(sessionID) - 1);
      return { error: { name: "NotFound" } };
    }
    if (tree.has(sessionID)) return { data: { parentID: tree.get(sessionID), location: { directory: "/tree" } } };
    return sessionID === "ses_lookup_child"
      ? { parentID: "ses_lookup_root", location: { directory: "/lookup-child" } }
      : { location: { directory: "/lookup-root" } };
  } },
  permission: { reply: async (value) => replies.push({ label, ...value }) },
});
const mod = await import(pathToFileURL(process.env.PW_OPENCODE_PLUGIN).href);
const cleanupA = await mod.default.setup(makeContext("A", "/other"));
const cleanupB = await mod.default.setup(makeContext("B", "/repo"));
const send = async (type, data, id, reverse = false, directory = "/repo") => {
  events.send({ id, type, data, location: { directory } }, reverse);
  await sleep(15);
};
const lines = () => existsSync(spool) ? readFileSync(spool, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
const records = () => lines();
const requestFiles = () => existsSync(requests) ? readdirSync(requests).filter((name) => name.endsWith(".json")) : [];
const nextRequest = async () => {
  for (let i = 0; i < 60; i++) {
    const [file] = requestFiles();
    if (file) return JSON.parse(readFileSync(join(requests, file), "utf8"));
    await sleep(25);
  }
  throw new Error("approval request was not written");
};
const startListening = () => { mkdirSync(approvals, { recursive: true }); writeFileSync(join(approvals, "listening"), ""); };
const decide = (id, value) => { mkdirSync(decisions, { recursive: true }); writeFileSync(join(decisions, id), value); };
let seq = 0;
const event = async (type, data, reverse = false, directory = "/repo") => {
  const id = `event-${++seq}`;
  await send(type, data, id, reverse, directory);
  return id;
};
const rootID = "ses_root";
await event("session.created", { sessionID: rootID, location: { directory: "/repo" } });
await event("session.inbox.enqueued", { sessionID: rootID, inboxID: "in-1", item: { type: "user", payload: { text: "First prompt" } } });
await event("session.inbox.enqueued", { sessionID: rootID, inboxID: "in-2", item: { type: "user", payload: { text: "Second prompt" } } });
await event("session.execution.started", { sessionID: rootID });
await event("session.inbox.delivered", { sessionID: rootID, inboxID: "in-1" });
await event("session.execution.started", { sessionID: rootID });
await event("session.inbox.delivered", { sessionID: rootID, inboxID: "in-2" });
await event("session.tool.input.started", { sessionID: rootID, id: "call-1", name: "shell" });
await event("session.tool.called", { sessionID: rootID, id: "call-1", input: { command: "PRIVATE_TOOL_INPUT" } });
await event("session.text.ended", { sessionID: rootID, text: "A useful reply\nwith a second line" });
await event("session.execution.succeeded", { sessionID: rootID });
const base = records();
check("two subscriptions deduplicate the shared server stream", base.filter((row) => row.event === "session.created").length === 1);
check("prompt FIFO uses oldest undelivered item, then advances after delivery",
  base.filter((row) => row.event === "session.execution.started").map((row) => row.prompt_head).join("|") === "First prompt|Second prompt");
check("tool name comes from input.started and tool input is never spooled",
  base.find((row) => row.event === "session.tool.called")?.tool_name === "shell" && !JSON.stringify(base).includes("PRIVATE_TOOL_INPUT"));
check("text ended is cached as a bounded one-line reply",
  !base.some((row) => row.event === "session.text.ended") && base.find((row) => row.event === "session.execution.succeeded")?.reply_head === "A useful reply with a second line");

const childID = "ses_child";
await event("session.created", { sessionID: childID, parentID: rootID, location: { directory: "/child" } });
await event("session.execution.started", { sessionID: childID });
check("child session creation and execution are dropped", !records().some((row) => row.session_id === childID));

startListening();
const nonMatchingFirstEventID = await event("permission.asked", { sessionID: childID, id: "per_allow", action: "shell", resources: ["printf ALLOW_OK"], message: "Approve shell" });
let req = await nextRequest();
check("child permission is written under root with Pi request format and capped input",
  req.agent === "opencode" && req.session_id === rootID && req.tool_name === "shell" &&
  req.tool_input.command === "printf ALLOW_OK" && req.answer_format === undefined && req.pid === process.pid);
check("non-matching context first still logs once and matching context opens one request",
  events.deliveries.filter((item) => item.id === nonMatchingFirstEventID).map((item) => item.label).join("|") === "A|B" &&
  records().filter((row) => row.event === "permission.asked" && row.request_id === "per_allow").length === 1 &&
  requestFiles().length === 1);
check("child permission record maps to root and child cwd", records().some((row) =>
  row.event === "permission.asked" && row.session_id === rootID && row.cwd === "/child" && row.title === "printf ALLOW_OK"));
decide(req.id, "allow");
await sleep(275);
check("allow calls OpenCode permission.reply with once on the asking session",
  replies.some((reply) => reply.requestID === "per_allow" && reply.sessionID === childID &&
    reply.decision === "once" && reply.label === "B"));

const matchingFirstEventID = await event("permission.asked", { sessionID: rootID, id: "per_match_first", action: "shell", resources: ["printf MATCH_FIRST"] }, true);
req = await nextRequest();
check("matching context first also logs once and opens one request",
  events.deliveries.filter((item) => item.id === matchingFirstEventID).map((item) => item.label).join("|") === "B|A" &&
  records().filter((row) => row.event === "permission.asked" && row.request_id === "per_match_first").length === 1 &&
  requestFiles().length === 1);
decide(req.id, "allow");
await sleep(275);
check("matching-first approval is replied to by its matching context",
  replies.some((reply) => reply.requestID === "per_match_first" && reply.decision === "once" && reply.label === "B"));

await event("permission.asked", { sessionID: rootID, id: "per_no_location_match", action: "shell", resources: ["printf NO_MATCH"] }, false, "/repo/subpath");
check("no exact location match still emits waiting without creating an approval request",
  records().filter((row) => row.event === "permission.asked" && row.request_id === "per_no_location_match").length === 1 &&
  !requestFiles().some((file) => file.includes("per_no_location_match")));

await event("permission.asked", { sessionID: rootID, id: "per_deny", action: "write", resources: ["/tmp/file"] });
req = await nextRequest();
decide(req.id, "deny");
await sleep(275);
check("deny calls permission.reply with reject, never always",
  replies.some((reply) => reply.requestID === "per_deny" && reply.decision === "reject") &&
  replies.every((reply) => reply.decision !== "always"));

await event("permission.asked", { sessionID: rootID, id: "per_cap", action: "shell", resources: ["x".repeat(5000)] });
req = await nextRequest();
check("approval tool input uses the 4,000-character Pi cap", req.tool_input._truncated?.length === 4000);
decide(req.id, "deny");
await sleep(275);

await event("permission.asked", { sessionID: rootID, id: "per_invalid", action: "shell", resources: ["echo no"] });
req = await nextRequest();
decide(req.id, "maybe");
await sleep(275);
check("invalid decision closes request without replying",
  !requestFiles().some((file) => file.includes("per_invalid")) && !replies.some((reply) => reply.requestID === "per_invalid"));

await event("permission.asked", { sessionID: rootID, id: "per_tui", action: "shell", resources: ["echo tui"] });
req = await nextRequest();
await event("permission.replied", { sessionID: rootID, requestID: "per_tui", reply: "once" });
await sleep(30);
check("TUI permission reply closes Pitwall request", !requestFiles().some((file) => file.includes("per_tui")));

await event("permission.asked", { sessionID: childID, id: "per_withdraw", action: "shell", resources: ["echo child"] });
await nextRequest();
await event("form.created", { form: { id: "form-child", sessionID: childID, title: "Child question", fields: [] } });
await event("session.execution.interrupted", { sessionID: childID, reason: "user" });
check("a stopped subagent withdraws its open permission and question on the root",
  records().some((row) => row.event === "permission.replied" && row.request_id === "per_withdraw" &&
    row.session_id === rootID && row.reason === "withdrawn") &&
  records().some((row) => row.event === "form.cancelled" && row.request_id === "form-child" && row.session_id === rootID) &&
  !requestFiles().some((file) => file.includes("per_withdraw")));

rmSync(join(approvals, "listening"), { force: true });
await event("permission.asked", { sessionID: rootID, id: "per_offline", action: "shell", resources: ["echo offline"] });
await sleep(30);
check("no listening heartbeat means no approval request file", !requestFiles().some((file) => file.includes("per_offline")));

// Real OpenCode 2.1.2 puts the session inside the form.
await event("form.created", { form: { id: "form-1", sessionID: rootID, title: "Question", fields: [{ description: "Choose a model" }] } });
await event("form.replied", { sessionID: rootID, id: "form-1" });
await event("form.cancelled", { sessionID: rootID, id: "form-2" });
await event("session.execution.failed", { sessionID: rootID, error: { message: "provider.free-limit" } });
await event("session.execution.interrupted", { sessionID: rootID, reason: "user" });
check("forms only emit waiting events with bounded titles; error and interruption fields survive",
  records().some((row) => row.event === "form.created" && row.request_id === "form-1" && row.title === "Choose a model") &&
  records().some((row) => row.event === "session.execution.failed" && row.error === "provider.free-limit") &&
  records().some((row) => row.event === "session.execution.interrupted" && row.reason === "user"));

const prompt = "x".repeat(100) + "SECRET_PROMPT_TAIL";
await event("session.inbox.enqueued", { sessionID: rootID, inboxID: "in-long", item: { type: "user", payload: { text: prompt } } });
await event("session.execution.started", { sessionID: rootID });
check("spool excludes long prompt body beyond the Pi excerpt limit", !JSON.stringify(records()).includes("SECRET_PROMPT_TAIL") &&
  records().findLast((row) => row.event === "session.execution.started")?.prompt_head?.length === 81);

await event("session.text.ended", { sessionID: rootID, text: "y".repeat(200) + "SECRET_REPLY_TAIL" });
await event("session.execution.succeeded", { sessionID: rootID });
check("reply excerpt is capped at 160 characters", !JSON.stringify(records()).includes("SECRET_REPLY_TAIL") &&
  records().findLast((row) => row.event === "session.execution.succeeded")?.reply_head?.length === 161);

await event("session.archived", { sessionID: rootID });
check("root archive is emitted", records().some((row) => row.event === "session.archived" && row.session_id === rootID));

await event("session.execution.started", { sessionID: "ses_lookup_root" });
await event("session.execution.failed", { sessionID: "ses_lookup_root", error: { message: "lookup complete" } });
await event("session.execution.started", { sessionID: "ses_lookup_child" });
await event("form.created", { form: { id: "form-hydrated", sessionID: "ses_lookup_child", title: "Hydrated" } });
check("unknown session cwd is hydrated once through session.get",
  lookups.filter((item) => item.sessionID === "ses_lookup_root").length === 1 &&
  records().some((row) => row.event === "session.execution.failed" && row.error === "lookup complete" && row.cwd === "/lookup-root"));
check("a child first seen before its lookup finishes never shows as its own session",
  !records().some((row) => row.session_id === "ses_lookup_child"));
check("session.get parentID maps later child events to the root",
  lookups.filter((item) => item.sessionID === "ses_lookup_child").length === 1 &&
  records().some((row) => row.event === "form.created" && row.request_id === "form-hydrated" &&
    row.session_id === "ses_lookup_root" && row.cwd === "/lookup-child"));

// Both contexts miss on the first try; the retry finds the parent.
tree.set("ses_slow_child", "ses_slow_root");
misses.set("ses_slow_child", 2);
await event("session.created", { sessionID: "ses_slow_root", location: { directory: "/repo" } });
await event("form.created", { form: { id: "form-slow", sessionID: "ses_slow_child", title: "Slow" } });
await sleep(700);
check("a lookup that misses is retried before a subagent could become a session of its own",
  records().some((row) => row.event === "form.created" && row.request_id === "form-slow" && row.session_id === "ses_slow_root") &&
  !records().some((row) => row.session_id === "ses_slow_child"));

// A creation that arrives while the session is looked up waits behind the events before it.
delays.set("ses_order", 100);
await event("form.created", { form: { id: "form-order", sessionID: "ses_order", title: "Order" } });
await event("session.created", { sessionID: "ses_order", location: { directory: "/repo" } });
await event("form.replied", { sessionID: "ses_order", id: "form-order" });
await sleep(200);
check("events of a session being looked up keep their order",
  records().filter((row) => row.session_id === "ses_order").map((row) => row.event).join("|") === "form.created|session.created|form.replied");

// Evicting a session forgets the subagents below it, so a deeper subagent is looked up again
// instead of mapping to a parent whose own link is gone.
tree.set("ses_evict_a", "ses_evict_root");
tree.set("ses_evict_b", "ses_evict_a");
await event("session.created", { sessionID: "ses_evict_root", location: { directory: "/repo" } });
await event("session.created", { sessionID: "ses_evict_a", parentID: "ses_evict_root" });
await event("session.created", { sessionID: "ses_evict_b", parentID: "ses_evict_a" });
for (let i = 0; i < 1000; i++) events.send({ id: `evict-${i}`, type: "session.created", data: { sessionID: `ses_fill_${i}` } });
await sleep(30);
await event("form.created", { form: { id: "form-evicted", sessionID: "ses_evict_b", title: "Evicted" } });
await sleep(100);
check("an evicted subagent tree is looked up again and still maps to its root",
  records().some((row) => row.event === "form.created" && row.request_id === "form-evicted" && row.session_id === "ses_evict_root") &&
  !records().some((row) => row.session_id === "ses_evict_a" || row.session_id === "ses_evict_b"));

// An instance stopped while its event waited for a lookup does not open an approval for it.
startListening();
const cleanupC = await mod.default.setup(makeContext("C", "/stopped"));
delays.set("ses_stopped", 100);
await event("permission.asked", { sessionID: "ses_stopped", id: "per_stopped", action: "shell", resources: ["echo stopped"] }, false, "/stopped");
await cleanupC();
await sleep(200);
check("a waiting permission of a stopped instance is reported but opens no approval",
  records().some((row) => row.event === "permission.asked" && row.request_id === "per_stopped") &&
  !requestFiles().some((file) => file.includes("per_stopped")));

const cleanupID = "ses_cleanup";
await event("session.created", { sessionID: cleanupID, location: { directory: "/repo" } });
startListening();
await event("permission.asked", { sessionID: cleanupID, id: "per_cleanup", action: "shell", resources: ["echo cleanup"] });
req = await nextRequest();
await cleanupA();
await cleanupB();
check("cleanup removes owned request files and aborts both subscriptions", !requestFiles().some((file) => file.includes("per_cleanup")) && events.subscribers === 0);
const before = records().length;
await event("session.deleted", { sessionID: cleanupID });
check("cleanup stops the event loop", records().length === before);

for (const [name, ok] of checks) console.log(`  ${ok ? "ok  " : "FAIL"} ${name}`);
if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
' 
