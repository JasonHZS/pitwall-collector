/**
 * pitwall 的 Pi 扩展：把 Pi 的生命周期事件脱敏后追加到 ~/.pitwall/events/pi.jsonl。
 *
 * 只观察、不干预：所有 handler 都不返回值——不拦截工具调用、不改 prompt、不回答 UI 提示。
 * 写盘失败静默忽略，保证扩展本身永远不会让 Pi 报错。
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const EVENTS_DIR = join(process.env.PITWALL_HOME || join(homedir(), ".pitwall"), "events");
const SPOOL = join(EVENTS_DIR, "pi.jsonl");

type Ctx = {
  cwd?: string;
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

export default function pitwall(pi: ExtensionAPI): void {
  pi.on("session_start", (event, ctx) => {
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
    emit("agent_start", ctx);
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
    emit("agent_end", ctx);
  });
  // Pi 不会再自动继续（重试/压缩/排队消息都已结束）时触发，是「本轮结束」的可靠信号。
  pi.on("agent_settled", (_event, ctx) => {
    emit("agent_settled", ctx);
  });
}
