/**
 * pitwall 的 Pi 扩展：把 Pi 的生命周期事件脱敏后追加到 ~/.pitwall/events/pi.jsonl。
 *
 * 事件只观察：所有 handler 都不返回值——不拦截工具调用、不改 prompt。
 * 写盘失败静默忽略，保证扩展本身永远不会让 Pi 报错。
 *
 * 审批：Pi 本身没有审批，审批框来自其它扩展（如命令守卫）在工具调用时弹出的 ctx.ui.select / confirm。
 * Pitwall 在监听时，这里把请求按 pitwall-approval 的文件格式交给 Pitwall，终端里的选择框照常显示，
 * 两边谁先回答算谁的：Pitwall 的回答会关闭终端选择框，并把对应选项交还给弹框的扩展。
 * 只接管 Agent 运行中、选项里恰好有一个“允许”和一个“拒绝”的选择框，以及确认框；其它提示原样不动。
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

type Ctx = {
  cwd?: string;
  hasUI?: boolean;
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

// ---- 审批 ----

type Decision = "allow" | "deny";
type DialogOptions = { signal?: AbortSignal; timeout?: number } | undefined;
type UI = {
  select?: (title: string, options: string[], opts?: DialogOptions) => Promise<string | undefined>;
  confirm?: (title: string, message: string, opts?: DialogOptions) => Promise<boolean>;
};

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

/**
 * 写一条待批请求并轮询 Pitwall 的决定。拿到决定时 wait 兑现；Pitwall 停止监听、请求被删除、
 * 等待超时或 close() 后清理文件，wait 永不兑现，只剩终端里的选择框。
 */
function openRequest(ctx: Ctx, title: string): { wait: Promise<Decision>; close: () => void } | undefined {
  if (!listening()) return undefined;
  const session = attempt(() => ctx.sessionManager?.getSessionId?.());
  if (typeof session !== "string" || !SAFE.test(session)) return undefined;
  // select / confirm 没有调用 ID，无法把弹框可靠地关联到工具；直接显示当前提示。
  const id = `${Math.floor(Date.now() / 1000)}-${process.pid}-${++sequence}`;
  const request = join(APPROVALS, "requests", `pi.${session}.prompt.${id}.json`);
  const decision = join(APPROVALS, "decisions", id);
  const record = {
    v: 1, id, agent: "pi", created_at: Date.now() / 1000, pid: process.pid, session_id: session,
    cwd: attempt(() => ctx.cwd), tool_name: "prompt",
    tool_input: capped({ prompt: title }),
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
  const close = () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    attempt(() => rmSync(request, { force: true }));
    attempt(() => rmSync(decision, { force: true }));
  };
  const started = Date.now();
  const wait = new Promise<Decision>((resolve) => {
    timer = setInterval(() => {
      const answer = attempt(() => (existsSync(decision) ? readFileSync(decision, "utf8").slice(0, 16).trim() : undefined));
      if (answer === "allow" || answer === "deny") {
        close();
        resolve(answer);
      } else if (!existsSync(request) || !listening() || Date.now() - started > LIMIT_MS) {
        close();
      }
    }, 200);
    // 轮询不能让 Pi 在退出时多等。
    attempt(() => timer?.unref?.());
  });
  return { wait, close };
}

/**
 * 终端选择框与 Pitwall 同时等待。Pitwall 先回答时用 AbortSignal 关掉终端选择框，
 * 再把映射后的答案交给弹框的扩展；终端先回答时撤回 Pitwall 里的请求。
 */
async function race<T>(ctx: Ctx, title: string, opts: DialogOptions, show: (opts: DialogOptions) => Promise<T>,
                       answer: (decision: Decision) => T): Promise<T> {
  const abortable = typeof AbortSignal.any === "function" || !opts?.signal;
  const request = agentRunning && abortable ? openRequest(ctx, title) : undefined;
  if (!request) return show(opts);
  const controller = new AbortController();
  const signal = opts?.signal ? AbortSignal.any([opts.signal, controller.signal]) : controller.signal;
  const local = show({ ...opts, signal }).then(
    (value) => ({ from: "terminal" as const, value }),
    (error: unknown) => ({ from: "terminal" as const, error }),
  );
  const result = await Promise.race([local, request.wait.then((decision) => ({ from: "pitwall" as const, decision }))]);
  if (result.from === "terminal") {
    request.close();
    if ("error" in result) throw result.error;
    return result.value;
  }
  controller.abort();
  await local;
  return answer(result.decision);
}

/** Pi 的 ctx.ui 是所有扩展共用的同一个对象：包住它的 select / confirm，其它扩展的弹框也经过这里。 */
function patchUI(ctx: Ctx): void {
  if (!attempt(() => ctx.hasUI)) return;
  const ui = attempt(() => ctx.ui) as UI | undefined;
  if (!ui || typeof ui !== "object" || patched.has(ui)) return;
  patched.add(ui);
  const select = ui.select;
  const confirm = ui.confirm;
  if (typeof select === "function") {
    ui.select = (title, options, opts) => {
      const choices = verdicts(options);
      if (!choices || typeof title !== "string") return select(title, options, opts);
      return race(ctx, title, opts, (o) => select(title, options, o), (d) => (d === "allow" ? choices.allow : choices.deny));
    };
  }
  if (typeof confirm === "function") {
    ui.confirm = (title, message, opts) => {
      if (typeof title !== "string") return confirm(title, message, opts);
      const text = typeof message === "string" && message.trim() !== "" ? `${title}\n\n${message}` : title;
      return race(ctx, text, opts, (o) => confirm(title, message, o), (d) => d === "allow");
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
  // 工具调用前再次检查共享 UI（Pi 重建 UI 后需要重新包住）；不读取工具参数。
  pi.on("tool_call", (_event, ctx) => {
    attempt(() => patchUI(ctx));
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
