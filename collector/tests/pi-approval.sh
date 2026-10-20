#!/bin/sh
# Pi 扩展的审批与提问接管：用假的 ctx.ui 模拟终端选择框与输入框，不启动 Pi、不读写真实配置。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pitwall-pi-approval.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PITWALL_HOME="$tmp/pitwall" PW_PI_EXT="$root/pi/pitwall.ts" node --no-warnings --input-type=module -e '
import { pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const appr = join(process.env.PITWALL_HOME, "approvals");
const requests = join(appr, "requests");
const listen = () => { mkdirSync(appr, { recursive: true }); writeFileSync(join(appr, "listening"), ""); };
const pending = () => existsSync(requests) ? readdirSync(requests).filter((f) => f.endsWith(".json")) : [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function nextRequest() {
  for (let i = 0; i < 50; i++) { const [f] = pending(); if (f) return JSON.parse(readFileSync(join(requests, f), "utf8")); await sleep(50); }
  throw new Error("no request");
}
const decide = (id, answer) => { mkdirSync(join(appr, "decisions"), { recursive: true }); writeFileSync(join(appr, "decisions", id), answer); };

// 假终端：选择框一直开着，直到被 signal 关闭（返回 undefined）或测试替用户作答。
const shown = [];
let answerInTerminal;
const dialog = (kind) => (...args) => new Promise((resolve) => {
  const opts = args[args.length - 1];
  const entry = { kind, args, closed: false };
  shown.push(entry);
  answerInTerminal = (value) => resolve(value);
  opts?.signal?.addEventListener("abort", () => { entry.closed = true; resolve(kind === "confirm" ? false : undefined); });
});
const ui = { select: dialog("select"), confirm: dialog("confirm"), input: dialog("input"), notify() {} };
const original = ui.select;
// 扩展的轮询计时器 unref 了，不拖住 Pi 退出；真实 Pi 的终端界面让进程一直运行，这里用计时器代替。
const alive = setInterval(() => {}, 1000);
const ctx = { cwd: "/tmp/pi-proj", hasUI: true, ui, sessionManager: { getSessionId: () => "pi-appr-1", getSessionFile: () => "/tmp/x.jsonl" } };

const mod = await import(pathToFileURL(process.env.PW_PI_EXT).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
let fails = 0;
const check = (desc, ok) => { console.log(`  ${ok ? "ok  " : "FAIL"} ${desc}`); if (!ok) fails++; };
const OPTIONS = ["Allow once", "Always allow “git”", "Reject"];

await handlers.session_start({ reason: "startup" }, ctx);
check("扩展包住共享的 ctx.ui", ui.select !== original);
listen();

// Agent 没在运行（如斜杠命令里的确认）：不接管。
let p = ui.select("Allow?", OPTIONS);
await sleep(300);
check("Agent 未运行时不写请求", pending().length === 0);
answerInTerminal("Reject"); await p;

await handlers.agent_start({}, ctx);
// Pi 1.2.0 先发 tool_execution_start，再按扩展加载顺序发 tool_call。
await handlers.tool_execution_start({ toolCallId: "c1", toolName: "bash" }, ctx);
await handlers.tool_call({ toolCallId: "c1", toolName: "bash", input: { command: "git push" } }, ctx);
const approvalTitle = "⚠️ Command approval required\n\n  $ git push";
p = ui.select(approvalTitle, OPTIONS);
let req = await nextRequest();
check("请求写明 Agent、会话、cwd、pid 与当前审批提示",
  req.v === 1 && req.agent === "pi" && req.session_id === "pi-appr-1" && req.cwd === "/tmp/pi-proj" && req.pid === process.pid &&
  req.tool_name === "prompt" && req.tool_input.prompt === approvalTitle && /^[A-Za-z0-9_.-]+$/.test(req.id));
decide(req.id, "allow");
check("Pitwall 批准映射为唯一的允许选项", (await p) === "Allow once");
check("批准后终端选择框被关闭", shown.at(-1).closed === true);
await sleep(50);
check("批准后清理请求与决定", pending().length === 0 && !existsSync(join(appr, "decisions", req.id)));
await handlers.tool_execution_end({ toolCallId: "c1", toolName: "bash" }, ctx);

// 并行批次先准备所有调用，工具结果尚未到来。守卫先于 Pitwall 加载时，
// 第二个调用先弹框，Pitwall 尚未收到它的 tool_call；不能拿第一个调用当审批内容。
await handlers.tool_execution_start({ toolCallId: "safe", toolName: "bash" }, ctx);
await handlers.tool_call({ toolCallId: "safe", toolName: "bash", input: { command: "echo safe" } }, ctx);
await handlers.tool_execution_start({ toolCallId: "delete", toolName: "bash" }, ctx);
const deleteTitle = "Approve rm -rf ./build?";
p = ui.select(deleteTitle, OPTIONS);
req = await nextRequest();
check("守卫先加载、同批第二调用的审批显示自身提示而非上一条命令",
  req.tool_name === "prompt" && req.tool_input.prompt === deleteTitle && req.tool_input.command === undefined);
decide(req.id, "deny");
check("同批第二调用拒绝仍返回守卫的 Reject", (await p) === "Reject");

p = ui.select("Allow?", OPTIONS);
req = await nextRequest();
decide(req.id, "deny");
check("Pitwall 拒绝映射为唯一的拒绝选项", (await p) === "Reject");

p = ui.select("Allow?", OPTIONS);
await nextRequest();
answerInTerminal("Always allow “git”");
check("终端先回答时返回终端的选项", (await p) === "Always allow “git”");
await sleep(50);
check("终端先回答时撤回 Pitwall 里的请求", pending().length === 0);

p = ui.confirm("Delete build/?", "rm -rf build");
req = await nextRequest();
check("确认框显示自己的标题与正文", req.tool_name === "prompt" && req.tool_input.prompt === "Delete build/?\n\nrm -rf build");
decide(req.id, "allow");
check("确认框批准返回 true", (await p) === true);
p = ui.confirm("Proceed?", "");
decide((await nextRequest()).id, "deny");
check("确认框拒绝返回 false", (await p) === false);

// 其它选择框是提问：只能在给定选项中选一个，Pitwall 的回答映射回原选项字符串。
for (const options of [["Option A", "Option B"], ["Allow once", "Allow for session", "Reject"], ["Yes", "No", "Cancel"]]) {
  p = ui.select("Pick one", options);
  req = await nextRequest();
  check(`不是唯一允许 / 拒绝的选择框作为提问：${options.join(" / ")}`,
    req.tool_name === "question" && req.answer_format === "answers-v1" &&
    JSON.stringify(req.tool_input) === JSON.stringify({ questions: [{ question: "Pick one", header: "",
      options: options.map((label) => ({ label })), allowOther: false }] }));
  decide(req.id, JSON.stringify({ answers: { "Pick one": options[1] } }));
  check(`提问回答返回所选选项：${options[1]}`, (await p) === options[1]);
}
for (const reply of ["allow", "{}", JSON.stringify({ answers: { "Pick one": "Not an option" } }), JSON.stringify({ answers: { "Pick one": " " } })]) {
  p = ui.select("Pick one", ["Option A", "Option B"]);
  req = await nextRequest();
  decide(req.id, reply);
  await sleep(400);
  check(`无效回答（${reply}）交回终端`, pending().length === 0 && shown.at(-1).closed === false);
  answerInTerminal("Option A");
  check(`无效回答之后仍以终端为准（${reply}）`, (await p) === "Option A");
}
for (const options of [["Same", "Same"], ["A", ""]]) {
  p = ui.select("Pick one", options);
  await sleep(250);
  check(`选项重复或为空的选择框不接管：${JSON.stringify(options)}`, pending().length === 0);
  answerInTerminal(options[0]); await p;
}
p = ui.input("Branch name?", "feature/…");
req = await nextRequest();
check("输入框作为只能填写文字的提问",
  req.tool_name === "question" && JSON.stringify(req.tool_input.questions) === JSON.stringify([{ question: "Branch name?", header: "", options: [], allowOther: true }]));
decide(req.id, JSON.stringify({ answers: { "Branch name?": "fix/登录\n第二行" } }));
check("输入框返回 Pitwall 填写的文字", (await p) === "fix/登录\n第二行");
check("Pitwall 回答后关闭终端输入框", shown.at(-1).closed === true);
p = ui.input("Branch name?");
await nextRequest();
answerInTerminal("main");
check("输入框终端先回答时返回终端的文字", (await p) === "main");
await sleep(50);
check("输入框终端先回答时撤回请求", pending().length === 0);

// 官方示例的提问工具：tool_call 先等 Pitwall，作答后阻止调用、回答写进原因。
let call = handlers.tool_call({ toolCallId: "q1", toolName: "questionnaire", input: { questions: [
  { id: "scope", label: "Scope", prompt: "Which scope?", options: [{ value: "a", label: "All", description: "Everything" }, { value: "m", label: "Mine" }] },
  { id: "note", prompt: "Anything else?", options: [], allowOther: true }] } }, ctx);
req = await nextRequest();
check("questionnaire 换成 Pitwall 题目（标签作 header，空选项为填写题）",
  req.tool_name === "question" && req.answer_format === "answers-v1" && JSON.stringify(req.tool_input.questions) === JSON.stringify([
    { question: "Which scope?", header: "Scope", options: [{ label: "All", description: "Everything" }, { label: "Mine" }], allowOther: true },
    { question: "Anything else?", header: "Q2", options: [], allowOther: true }]));
const toolAnswers = { "Which scope?": "Mine", "Anything else?": "无" };
decide(req.id, JSON.stringify({ answers: toolAnswers }));
let result = await call;
check("questionnaire 回答后阻止调用并把回答交给模型",
  result?.block === true && JSON.parse(result.reason.split("\n").slice(1).join("\n"))["Which scope?"] === "Mine");
await sleep(50);
check("提问工具回答后清理请求", pending().length === 0);
call = handlers.tool_call({ toolCallId: "q2", toolName: "question", input: { question: "Color?", options: [{ label: "Red" }] } }, ctx);
req = await nextRequest();
decide(req.id, JSON.stringify({ answers: { "Other?": "x" } }));
check("question 工具的无效回答照常运行工具", (await call) === undefined);
call = handlers.tool_call({ toolCallId: "q3", toolName: "question", input: { question: "Color?", options: [{ label: "Red" }] } }, ctx);
await nextRequest();
const stale = new Date(Date.now() - 60_000);
utimesSync(join(appr, "listening"), stale, stale);
check("停止监听时提问工具不再等待", (await call) === undefined && pending().length === 0);
listen();
const aborted = new AbortController();
aborted.abort();
check("中断后的提问工具立即照常运行、不留请求", (await handlers.tool_call({ toolCallId: "q5", toolName: "question",
  input: { question: "Color?", options: [{ label: "Red" }] } }, { ...ctx, signal: aborted.signal })) === undefined && pending().length === 0);
check("其它工具的 tool_call 不写请求", (await handlers.tool_call({ toolCallId: "b", toolName: "bash", input: { command: "ls" } }, ctx)) === undefined && pending().length === 0);
check("重复题目的 questionnaire 不接管", (await handlers.tool_call({ toolCallId: "q4", toolName: "questionnaire",
  input: { questions: [{ prompt: "Same?", options: [{ label: "A" }] }, { prompt: "Same?", options: [{ label: "B" }] }] } }, ctx)) === undefined);

// 调用方自己的 signal 仍能关闭选择框。
const own = new AbortController();
p = ui.select("Allow?", OPTIONS, { signal: own.signal });
await nextRequest();
own.abort();
check("调用方的 signal 照常关闭选择框", (await p) === undefined);
await sleep(50);
check("调用方关闭后撤回请求", pending().length === 0);

// Pitwall 停止监听：请求撤回，终端选择框继续等用户。
p = ui.select("Allow?", OPTIONS);
await nextRequest();
const old = new Date(Date.now() - 60_000);
utimesSync(join(appr, "listening"), old, old);
await sleep(400);
check("停止监听后撤回请求，终端选择框仍开着", pending().length === 0 && shown.at(-1).closed === false);
answerInTerminal("Reject");
check("之后仍以终端回答为准", (await p) === "Reject");
p = ui.select("Allow?", OPTIONS);
await sleep(250);
check("没在监听时不写请求", pending().length === 0);
answerInTerminal("Allow once"); await p;
listen();

await handlers.agent_end({ messages: [] }, ctx);
p = ui.select("Allow?", OPTIONS);
await sleep(250);
check("Agent 结束后不再接管", pending().length === 0);
answerInTerminal("Reject"); await p;

// 无 UI（打印 / RPC 模式）的 ctx 不被包住。
const headless = { select: async () => undefined };
await handlers.session_start({ reason: "startup" }, { ...ctx, hasUI: false, ui: headless });
check("无 UI 时不包住 ctx.ui", headless.select.toString().includes("async () => undefined"));
rmSync(appr, { recursive: true, force: true });
console.log(`Pi 审批与提问检查：${fails} 项失败`);
clearInterval(alive);
process.exit(fails === 0 ? 0 : 1);
'
