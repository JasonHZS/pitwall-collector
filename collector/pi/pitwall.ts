/**
 * pitwall 的 Pi 扩展：把 Pi 的生命周期事件脱敏后追加到 ~/.pitwall/events/pi.jsonl。
 *
 * 事件只观察：除下面的提问工具外，handler 都不返回值——不拦截其它工具调用、不改 prompt。
 * 写盘失败静默忽略，保证扩展本身永远不会让 Pi 报错。
 *
 * 审批：Pi 本身没有审批，审批框来自其它扩展（如命令守卫）在工具调用时弹出的 ctx.ui.select / confirm。
 * Pitwall 在监听时，这里把请求按 pitwall-approval 的文件格式交给 Pitwall，终端里的选择框照常显示，
 * 两边谁先回答算谁的：Pitwall 的回答会关闭终端选择框，并把对应选项交还给弹框的扩展。
 * 只接管 Agent 运行中、选项里恰好有一个“允许”和一个“拒绝”的选择框，以及确认框。
 *
 * 提问：Agent 运行中其它扩展弹出的普通选择框（ctx.ui.select）与输入框（ctx.ui.input）以 question 请求
 * （answer_format=answers-v1）交给 Pitwall 作答，同样与终端同时等待；选择框只能选给定的选项。
 * Pi 官方示例的提问工具 question / questionnaire 用自绘界面，包不住：在 tool_call 里先把题目交给 Pitwall，
 * 最多等 60 秒；用户在 Pitwall 作答后阻止这次调用、把回答写进原因交给模型，否则照常显示工具自己的界面。
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PITWALL_HOME = process.env.PITWALL_HOME || join(homedir(), ".pitwall");
const EVENTS_DIR = join(PITWALL_HOME, "events");
const SPOOL = join(EVENTS_DIR, "pi.jsonl");
const APPROVALS = join(PITWALL_HOME, "approvals");
const LIMIT_MS = 900_000;
/** 提问工具的界面要等 tool_call 返回才出现，终端这段时间看不到题目，所以只等 60 秒。 */
const TOOL_WAIT_MS = 60_000;

type Ctx = {
  cwd?: string;
  hasUI?: boolean;
  signal?: AbortSignal;
  ui?: unknown;
  sessionManager?: {
    getSessionId?: () => string | undefined;
    getSessionFile?: () => string | undefined;
  };
};

function cut(value: unknown, n: number): string | undefined {
  if (typeof value !== "string") return undefined;
  return value.length > n ? `${value.slice(0, n)}…` : value;
}

function firstLine(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return cut((value.split(/\r?\n/).find((line) => line.trim() !== "") ?? "").trim(), 80);
}

// 与 pitwall-hook 相同：开头成对标签包住的注入块（<tag …>…</tag> 或 <tag …/>）先剥掉，只留标签名；
// 剥完只剩空白时退回原文。
const WRAPPER = /^\s*<([A-Za-z][A-Za-z0-9_.:-]*)(?:\s[^<>]*)?(?:\/>|>[\s\S]*?<\/\1\s*>)/;
function promptParts(value: unknown): { text: unknown; tags: string[] } {
  if (typeof value !== "string") return { text: value, tags: [] };
  let text = value;
  const tags: string[] = [];
  let match: RegExpExecArray | null;
  while ((match = WRAPPER.exec(text))) {
    if (tags.length < 8) tags.push(/^[A-Za-z0-9_.-]{1,40}$/.test(match[1]) ? match[1] : "?");
    text = text.slice(match[0].length);
  }
  return text.trim() === "" ? { text: value, tags: [] } : { text, tags };
}

// 回复正文只留开头：文本块拼起来压成一行，取前 n 字；thinking、工具调用等非文本块不读。
function replyHead(content: unknown, n: number): string | undefined {
  const text =
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content
            .filter((part) => part?.type === "text" && typeof part.text === "string")
            .map((part) => part.text)
            .join(" ")
        : undefined;
  const line = text?.replace(/\s+/g, " ").trim();
  return line ? cut(line, n) : undefined;
}

function attempt<T>(fn: () => T): T | undefined {
  try {
    return fn();
  } catch {
    return undefined;
  }
}

// 本进程的控制终端（如 ttys003）：Pi 没有提供，只在会话开始 / 每轮开始时查一次，失败就不记。
function controllingTTY(): string | undefined {
  const tty = attempt(() =>
    execFileSync("/bin/ps", ["-o", "tty=", "-p", String(process.pid)], { timeout: 500, encoding: "utf8" }).trim(),
  );
  return tty && tty !== "??" ? tty : undefined;
}

// 进程与终端线索，供之后「返回原会话」使用。proc 与 shell hook 的格式一致。
function processContext() {
  const env = process.env;
  const tty = controllingTTY();
  return {
    proc: tty ? { pid: String(process.pid), ppid: String(process.ppid), tty, comm: "pi" } : undefined,
    pid: process.pid,
    ppid: process.ppid,
    term_program: env.TERM_PROGRAM,
    term_session_id: env.TERM_SESSION_ID,
    iterm_session_id: env.ITERM_SESSION_ID,
    tmux_pane: env.TMUX_PANE,
    tmux_socket: env.TMUX && /^\/[^\r\n]*,[0-9]+,[0-9]+$/.test(env.TMUX) ? env.TMUX.replace(/,[0-9]+,[0-9]+$/, "") : undefined,
    bundle_id: env.__CFBundleIdentifier,
    ghostty_env: Object.keys(env).filter((k) => k.startsWith("GHOSTTY_")).join(" ") || undefined,
  };
}

function emit(event: string, ctx: Ctx | undefined, extra: Record<string, unknown> = {}): void {
  try {
    const record = {
      v: 1,
      ts: Date.now(),
      agent: "pi",
      event,
      session_id: attempt(() => ctx?.sessionManager?.getSessionId?.()),
      cwd: ctx?.cwd,
      transcript_path: attempt(() => ctx?.sessionManager?.getSessionFile?.()),
      ...extra,
    };
    mkdirSync(EVENTS_DIR, { recursive: true });
    appendFileSync(SPOOL, `${JSON.stringify(record)}\n`);
  } catch {
    // 观察者失败不能影响 Pi。
  }
}

// ---- 审批与提问 ----

type DialogOptions = { signal?: AbortSignal; timeout?: number } | undefined;
type UI = {
  select?: (title: string, options: string[], opts?: DialogOptions) => Promise<string | undefined>;
  confirm?: (title: string, message: string, opts?: DialogOptions) => Promise<boolean>;
  input?: (title: string, placeholder?: string, opts?: DialogOptions) => Promise<string | undefined>;
};
/** 请求文件里描述“问什么”的字段；accept 把 Pitwall 写来的决定文件内容换成弹框的返回值，无效时 undefined。 */
type Ask<T> = { tool_name: string; tool_input: unknown; answer_format?: string; accept: (reply: string) => T | undefined };

const SAFE = /^[A-Za-z0-9_.-]{1,128}$/;
const ALLOW = /^\s*(allow|approve|yes|run|accept)\b/i;
const DENY = /^\s*(reject|deny|no|block|decline|cancel)\b/i;
const patched = new WeakSet<object>();
let agentRunning = false;
let sequence = 0;

/** Pitwall 每 2 秒刷新心跳文件；超过 6 秒没更新就当它没在监听。 */
function listening(): boolean {
  const beat = attempt(() => statSync(join(APPROVALS, "listening")).mtimeMs);
  return beat !== undefined && Date.now() - beat <= 6_000;
}

/** 选项里各恰好一个“允许”与“拒绝”时返回它们；否则不是审批框，不接管。 */
function verdicts(options: unknown): { allow: string; deny: string } | undefined {
  if (!Array.isArray(options) || !options.every((option) => typeof option === "string")) return undefined;
  const allow = options.filter((option) => ALLOW.test(option));
  const deny = options.filter((option) => DENY.test(option));
  return allow.length === 1 && deny.length === 1 ? { allow: allow[0], deny: deny[0] } : undefined;
}

function capped(value: unknown): unknown {
  const json = JSON.stringify(value) ?? "";
  return json.length > 4000 ? { _truncated: json.slice(0, 4000) } : value;
}

/** 审批：决定文件是 allow / deny。 */
function approval<T>(prompt: string, allow: T, deny: T): Ask<T> {
  return {
    tool_name: "prompt", tool_input: capped({ prompt }),
    accept: (reply) => (reply.trim() === "allow" ? allow : reply.trim() === "deny" ? deny : undefined),
  };
}

/** 提问：一道题，即只有一题的 toolAsk。options 为空时是只能输入文字的题。 */
function question(title: string, options: string[], allowOther: boolean, accept: (answer: string) => string | undefined): Ask<string> {
  const ask = toolAsk([{ question: title, header: "", options: options.map((label) => ({ label })), allowOther }]);
  return { ...ask, accept: (reply) => { const answers = ask.accept(reply); return answers ? accept(answers[title]) : undefined; } };
}

type Question = { question: string; header: string; options: { label: string; description?: string }[]; allowOther: boolean };
/** 与 bin/pitwall-approval 里交给 Codex / Devin 的回答原因一字不差；两边一起改。 */
const ANSWERED = "The user answered your questions in Pitwall. This is their reply, not an error: continue with these answers and do not ask again.\n";

/** 提问工具的输入换成 Pitwall 的题目；不认识或 Pitwall 显示不了的返回 undefined，照常运行工具。 */
function toolQuestions(toolName: unknown, input: unknown): Question[] | undefined {
  const value = input as Record<string, unknown> | undefined;
  const options = (list: unknown) =>
    Array.isArray(list) ? list.map((o) => ({ label: o?.label, ...(typeof o?.description === "string" ? { description: o.description } : {}) })) : undefined;
  let questions: unknown[] | undefined;
  if (toolName === "question") {
    questions = [{ question: value?.question, header: "", options: options(value?.options), allowOther: true }];
  } else if (toolName === "questionnaire" && Array.isArray(value?.questions)) {
    questions = value.questions.map((q: any, i: number) => ({
      question: q?.prompt, header: typeof q?.label === "string" && q.label ? q.label : `Q${i + 1}`,
      options: options(q?.options), allowOther: q?.allowOther !== false,
    }));
  }
  if (!questions || questions.length === 0) return undefined;
  const valid = questions.every((q: any) => Array.isArray(q.options) && (q.options.length > 0 || q.allowOther) &&
    answerable(q.question, q.options.map((o: any) => o.label)));
  const texts = questions.map((q: any) => q.question);
  return valid && new Set(texts).size === texts.length ? (questions as Question[]) : undefined;
}

/** 提问：决定文件是 {"answers": {题目: 答案}}，每道题都有非空回答、没有多余的题才算数，其余一律交回原来的界面。 */
function toolAsk(questions: Question[]): Ask<Record<string, string>> {
  return {
    tool_name: "question", answer_format: "answers-v1", tool_input: { questions },
    accept: (reply) => {
      const answers = attempt(() => (JSON.parse(reply) as { answers?: unknown })?.answers) as Record<string, unknown> | undefined;
      if (!answers || typeof answers !== "object" || Object.keys(answers).length !== questions.length) return undefined;
      return questions.every((q) => typeof answers[q.question] === "string" && (answers[q.question] as string).trim() !== "")
        ? (answers as Record<string, string>) : undefined;
    },
  };
}

/** Pitwall 的表单要求题目非空、选项非空且不重复；做不到的提示只留在终端。 */
function answerable(title: unknown, options: unknown[]): title is string {
  return typeof title === "string" && title.trim() !== "" &&
    options.every((option) => typeof option === "string" && option !== "") && new Set(options).size === options.length;
}

/**
 * 写一条请求并轮询 Pitwall 的决定。拿到有效决定时 wait 兑现；决定无效、Pitwall 停止监听、请求被删除、
 * 等待超时或 close() 后清理文件，wait 永不兑现，只剩终端里的提示。
 * done 总会兑现一次：有效决定的值，或请求结束时的 undefined。
 */
function openRequest<T>(ctx: Ctx, ask: Ask<T>, limitMs = LIMIT_MS):
  { wait: Promise<T>; done: Promise<T | undefined>; close: () => void } | undefined {
  if (!listening()) return undefined;
  const session = attempt(() => ctx.sessionManager?.getSessionId?.());
  if (typeof session !== "string" || !SAFE.test(session)) return undefined;
  // select / confirm 没有调用 ID，无法把弹框可靠地关联到工具；直接显示当前提示。
  const id = `${Math.floor(Date.now() / 1000)}-${process.pid}-${++sequence}`;
  const request = join(APPROVALS, "requests", `pi.${session}.${ask.tool_name}.${id}.json`);
  const decision = join(APPROVALS, "decisions", id);
  const record = {
    v: 1, id, agent: "pi", created_at: Date.now() / 1000, pid: process.pid, session_id: session,
    cwd: attempt(() => ctx.cwd), tool_name: ask.tool_name, tool_input: ask.tool_input,
    ...(ask.answer_format ? { answer_format: ask.answer_format } : {}),
  };
  const written = attempt(() => {
    mkdirSync(join(APPROVALS, "requests"), { recursive: true });
    mkdirSync(join(APPROVALS, "decisions"), { recursive: true });
    chmodSync(APPROVALS, 0o700);
    writeFileSync(`${request}.tmp`, JSON.stringify(record));
    renameSync(`${request}.tmp`, request);
    return true;
  });
  if (!written) {
    attempt(() => rmSync(`${request}.tmp`, { force: true }));
    return undefined;
  }
  let timer: ReturnType<typeof setInterval> | undefined;
  let finish: (value: T | undefined) => void = () => {};
  const done = new Promise<T | undefined>((resolve) => { finish = resolve; });
  const close = () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    attempt(() => rmSync(request, { force: true }));
    attempt(() => rmSync(decision, { force: true }));
    finish(undefined);
  };
  const started = Date.now();
  const wait = new Promise<T>((resolve) => {
    timer = setInterval(() => {
      // Pitwall 原子写入决定文件，读到的总是完整内容；无效内容不猜，交回终端。
      const reply = attempt(() => (existsSync(decision) ? readFileSync(decision, "utf8") : undefined));
      const value = reply === undefined ? undefined : ask.accept(reply);
      if (value !== undefined) {
        // 先兑现 done，close() 里的 undefined 就不会盖过回答。
        finish(value);
        close();
        resolve(value);
      } else if (reply !== undefined || !existsSync(request) || !listening() || Date.now() - started > limitMs) {
        close();
      }
    }, 200);
    // 轮询不能让 Pi 在退出时多等。
    attempt(() => timer?.unref?.());
  });
  return { wait, done, close };
}

/**
 * 终端选择框与 Pitwall 同时等待。Pitwall 先回答时用 AbortSignal 关掉终端选择框，
 * 再把映射后的答案交给弹框的扩展；终端先回答时撤回 Pitwall 里的请求。
 */
async function race<T>(ctx: Ctx, ask: Ask<T>, opts: DialogOptions, show: (opts: DialogOptions) => Promise<T>): Promise<T> {
  const abortable = typeof AbortSignal.any === "function" || !opts?.signal;
  const request = agentRunning && abortable ? openRequest(ctx, ask) : undefined;
  if (!request) return show(opts);
  const controller = new AbortController();
  const signal = opts?.signal ? AbortSignal.any([opts.signal, controller.signal]) : controller.signal;
  const local = show({ ...opts, signal }).then(
    (value) => ({ from: "terminal" as const, value }),
    (error: unknown) => ({ from: "terminal" as const, error }),
  );
  const result = await Promise.race([local, request.wait.then((value) => ({ from: "pitwall" as const, value }))]);
  if (result.from === "terminal") {
    request.close();
    if ("error" in result) throw result.error;
    return result.value;
  }
  controller.abort();
  await local;
  return result.value;
}

/** Pi 的 ctx.ui 是所有扩展共用的同一个对象：包住它的 select / confirm / input，其它扩展的弹框也经过这里。 */
function patchUI(ctx: Ctx): void {
  if (!attempt(() => ctx.hasUI)) return;
  const ui = attempt(() => ctx.ui) as UI | undefined;
  if (!ui || typeof ui !== "object" || patched.has(ui)) return;
  patched.add(ui);
  const select = ui.select;
  const confirm = ui.confirm;
  const input = ui.input;
  if (typeof select === "function") {
    ui.select = (title, options, opts) => {
      const show = (o: DialogOptions) => select(title, options, o);
      if (typeof title !== "string" || !Array.isArray(options)) return select(title, options, opts);
      const choices = verdicts(options);
      if (choices) return race(ctx, approval(title, choices.allow, choices.deny), opts, show);
      if (!answerable(title, options)) return select(title, options, opts);
      return race<string | undefined>(ctx, question(title, options, false, (answer) => (options.includes(answer) ? answer : undefined)), opts, show);
    };
  }
  if (typeof confirm === "function") {
    ui.confirm = (title, message, opts) => {
      if (typeof title !== "string") return confirm(title, message, opts);
      const text = typeof message === "string" && message.trim() !== "" ? `${title}\n\n${message}` : title;
      return race(ctx, approval(text, true, false), opts, (o) => confirm(title, message, o));
    };
  }
  if (typeof input === "function") {
    ui.input = (title, placeholder, opts) => {
      if (!answerable(title, [])) return input(title, placeholder, opts);
      return race<string | undefined>(ctx, question(title, [], true, (answer) => answer), opts, (o) => input(title, placeholder, o));
    };
  }
}

export default function pitwall(pi: ExtensionAPI): void {
  pi.on("session_start", (event, ctx) => {
    attempt(() => patchUI(ctx));
    emit("session_start", ctx, { reason: event?.reason, ctx: processContext() });
  });
  pi.on("session_shutdown", (event, ctx) => {
    emit("session_shutdown", ctx, { reason: event?.reason });
  });
  pi.on("before_agent_start", (event, ctx) => {
    const prompt = promptParts(event?.prompt);
    emit("before_agent_start", ctx, {
      prompt_head: firstLine(prompt.text),
      prompt_wrappers: prompt.tags.length > 0 ? prompt.tags : undefined,
      ctx: processContext(),
    });
  });
  pi.on("agent_start", (_event, ctx) => {
    agentRunning = true;
    attempt(() => patchUI(ctx));
    emit("agent_start", ctx);
  });
  // 工具调用前再次检查共享 UI（Pi 重建 UI 后需要重新包住）。只读取提问工具的参数。
  pi.on("tool_call", async (event, ctx) => {
    attempt(() => patchUI(ctx));
    if (!agentRunning || !attempt(() => ctx.hasUI)) return undefined;
    const questions = attempt(() => toolQuestions(event?.toolName, event?.input));
    const request = questions ? openRequest(ctx, toolAsk(questions), TOOL_WAIT_MS) : undefined;
    if (!request) return undefined;
    // 用户在 Pi 里中断本轮时撤回，不让中断干等。
    const signal = attempt(() => ctx.signal);
    if (signal?.aborted) request.close();
    else signal?.addEventListener("abort", request.close, { once: true });
    const answers = await request.done;
    signal?.removeEventListener("abort", request.close);
    request.close();
    return answers ? { block: true, reason: ANSWERED + JSON.stringify(answers) } : undefined;
  });
  pi.on("tool_execution_start", (event, ctx) => {
    emit("tool_execution_start", ctx, { tool_name: event?.toolName });
  });
  pi.on("tool_execution_end", (event, ctx) => {
    emit("tool_execution_end", ctx, { tool_name: event?.toolName, is_error: event?.isError });
  });
  // 等待用户：任何扩展（如权限扩展）弹出 confirm/select/input 时触发。
  pi.on("ui_prompt_start", (event, ctx) => {
    emit("ui_prompt_start", ctx, { kind: event?.kind, title: cut(event?.title, 120) });
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    emit("ui_prompt_end", ctx);
  });
  // 只记录结束一轮的 assistant 消息（stop / error / aborted），跳过中间的 toolUse。
  // reply_head 是这条回复压成一行的前 160 字，用来在看板上显示「结果如何」。
  pi.on("message_end", (event, ctx) => {
    const message = event?.message as
      | { role?: string; stopReason?: string; errorMessage?: string; content?: unknown }
      | undefined;
    if (message?.role !== "assistant" || !message.stopReason || message.stopReason === "toolUse") return;
    emit("message_end", ctx, {
      stop_reason: message.stopReason,
      error: cut(message.errorMessage, 200),
      reply_head: attempt(() => replyHead(message.content, 160)),
    });
  });
  pi.on("agent_end", (_event, ctx) => {
    agentRunning = false;
    emit("agent_end", ctx);
  });
  // Pi 不会再自动继续（重试/压缩/排队消息都已结束）时触发，是「本轮结束」的可靠信号。
  pi.on("agent_settled", (_event, ctx) => {
    emit("agent_settled", ctx);
  });
}
