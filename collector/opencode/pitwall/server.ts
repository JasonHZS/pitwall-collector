import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const HOME = process.env.PITWALL_HOME || join(homedir(), ".pitwall")
const EVENTS = join(HOME, "events", "opencode.jsonl")
const APPROVALS = join(HOME, "approvals")
const LIMIT_MS = 900_000
const SAFE = /^[A-Za-z0-9_.-]{1,128}$/
const PROMPT_LIMIT = 80
const REPLY_LIMIT = 160
const TITLE_LIMIT = 120
// The server outlives many sessions; per-session state is capped and the oldest is forgotten.
const SESSION_LIMIT = 1000
const LOOKUP_MS = 2_000
const LOOKUP_TRIES = 3
const LOOKUP_RETRY_MS = 500

type Event = { id?: string; type?: string; location?: { directory?: string }; data?: Record<string, any> }
type Pending = {
  requestID: string
  sessionID: string
  owner: Set<string>
  requestFile: string
  decisionFile: string
  timer: ReturnType<typeof setInterval>
}
type Deferred = { ctx: any; event: Event; owned: Set<string> }
type State = {
  handled: Set<string>
  known: Set<string>
  roots: Map<string, string>
  cwd: Map<string, string>
  resolving: Map<string, Promise<void>>
  deferred: Map<string, Deferred[]>
  contexts: Set<any>
  prompts: Map<string, { inboxID: string; text: string }[]>
  tools: Map<string, Map<string, string>>
  replies: Map<string, string>
  asks: Map<string, { sessionID: string; form: boolean }>
  approvals: Map<string, Pending>
  counter: number
}

// One state per server process, shared by every location's plugin instance and kept across
// plugin reloads; fields added by a newer plugin are filled in on an older state.
const host = globalThis as any
const key = Symbol.for("pitwall.opencode")
const state: State = host[key] ??= {} as State
state.handled ??= new Set()
state.known ??= new Set()
state.roots ??= new Map()
state.cwd ??= new Map()
state.resolving ??= new Map()
state.deferred ??= new Map()
state.contexts ??= new Set()
state.prompts ??= new Map()
state.tools ??= new Map()
state.replies ??= new Map()
state.asks ??= new Map()
state.approvals ??= new Map()
state.counter ??= 0

function attempt<T>(fn: () => T): T | undefined {
  try {
    return fn()
  } catch {
    return undefined
  }
}

function safeID(value: string): boolean {
  return value !== "." && value !== ".." && SAFE.test(value)
}

function cut(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined
  return value.length > limit ? `${value.slice(0, limit)}…` : value
}

function excerpt(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined
  const line = value.replace(/\s+/g, " ").trim()
  return line ? cut(line, limit) : undefined
}

function firstLine(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined
  const line = value.split(/\r?\n/).find((item) => item.trim())?.trim()
  return line ? cut(line, limit) : undefined
}

function listening(): boolean {
  const beat = attempt(() => statSync(join(APPROVALS, "listening")).mtimeMs)
  return beat !== undefined && Date.now() - beat <= 6_000
}

function rootOf(sessionID: string): string {
  let root = sessionID
  const seen = new Set<string>()
  while (state.roots.has(root) && !seen.has(root)) {
    seen.add(root)
    root = state.roots.get(root)!
  }
  return root
}

/// form.created carries its session inside the form.
function sessionOf(event: Event): unknown {
  return event.data?.sessionID ?? event.data?.form?.sessionID
}

function forget(sessionID: string) {
  state.known.delete(sessionID)
  state.roots.delete(sessionID)
  state.cwd.delete(sessionID)
  state.prompts.delete(sessionID)
  state.tools.delete(sessionID)
  state.replies.delete(sessionID)
}

/// Forgets a session and every subagent below it, so no child is left mapping to a parent whose
/// own link is gone; a forgotten child is looked up again on its next event.
function forgetTree(sessionID: string) {
  for (const childID of [...state.roots.keys()]) {
    let parent = state.roots.get(childID)
    const seen = new Set<string>()
    while (parent !== undefined && parent !== sessionID && !seen.has(parent)) {
      seen.add(parent)
      parent = state.roots.get(parent)
    }
    if (parent === sessionID) forget(childID)
  }
  forget(sessionID)
}

/// Keeps `known` in order of last use, so the cap forgets idle sessions, not active ones.
function touch(sessionID: string) {
  for (const id of new Set([sessionID, rootOf(sessionID)])) {
    if (!state.known.delete(id)) continue
    state.known.add(id)
  }
}

function learn(sessionID: string, directory: unknown, parentID: unknown) {
  if (typeof directory === "string") state.cwd.set(sessionID, directory)
  if (typeof parentID === "string") state.roots.set(sessionID, parentID)
  state.known.add(sessionID)
  touch(sessionID)
  while (state.known.size > SESSION_LIMIT) forgetTree(state.known.values().next().value!)
}

async function lookup(ctx: any, sessionID: string): Promise<any> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise((resolve) => { timer = setTimeout(resolve, LOOKUP_MS) })
  try {
    return await Promise.race([Promise.resolve(ctx.session.get({ sessionID })).catch(() => undefined), timeout])
  } finally {
    clearTimeout(timer)
  }
}

async function find(sessionID: string, first: any): Promise<any> {
  for (let tries = 1; ; tries++) {
    // Contexts are read on every try, so instances that started or stopped meanwhile count.
    for (const ctx of [first, ...[...state.contexts].filter((item) => item !== first)]) {
      const result = await lookup(ctx, sessionID).catch(() => undefined)
      // The SDK answers { data } or { error }; an error is a miss, not a session without a parent.
      const session = result?.data ?? (result?.error ? undefined : result)
      if (session) return session
    }
    if (tries >= LOOKUP_TRIES) return undefined
    await new Promise<void>((done) => {
      const timer = setTimeout(done, LOOKUP_RETRY_MS * tries)
      attempt(() => timer.unref())
    })
  }
}

/// Finds an unseen session's directory and parent. session.get is location-scoped, so each
/// instance's context is tried; a parent is resolved too, so a nested subagent maps to its root.
/// A failed lookup is retried before the session is taken as a root, so a slow server does not
/// turn a subagent into a session of its own; only a session no context can find ends up so.
function resolve(sessionID: string, first: any): Promise<void> {
  const running = state.resolving.get(sessionID)
  if (running) return running
  // Learning the session and replaying what waited happen in one step, so a newer event of the
  // session cannot overtake the deferred ones.
  const settle = (directory?: unknown, parentID?: unknown) => {
    if (!state.resolving.has(sessionID)) return
    state.resolving.delete(sessionID)
    learn(sessionID, directory, parentID)
    const queue = state.deferred.get(sessionID) ?? []
    state.deferred.delete(sessionID)
    for (const item of queue) attempt(() => handle(item.ctx, item.event, item.owned))
  }
  const task = (async () => {
    const session = await find(sessionID, first)
    const parentID = typeof session?.parentID === "string" ? session.parentID : undefined
    if (parentID && !state.known.has(parentID)) await resolve(parentID, first)
    settle(session?.location?.directory, parentID)
  })().catch(() => settle())
  state.resolving.set(sessionID, task)
  return task
}

function claim(id: string): boolean {
  if (state.handled.has(id)) return false
  state.handled.add(id)
  if (state.handled.size > 2000) state.handled.delete(state.handled.values().next().value!)
  return true
}

function emit(event: string, sessionID: string, cwd: string | undefined, extra: Record<string, unknown> = {}) {
  attempt(() => {
    mkdirSync(join(HOME, "events"), { recursive: true })
    appendFileSync(EVENTS, `${JSON.stringify({
      v: 1, ts: Date.now(), agent: "opencode", event, session_id: sessionID, cwd, ctx: { pid: process.pid }, ...extra,
    })}\n`)
  })
}

function closeApproval(id: string) {
  const pending = state.approvals.get(id)
  if (!pending) return
  clearInterval(pending.timer)
  attempt(() => rmSync(pending.requestFile, { force: true }))
  attempt(() => rmSync(pending.decisionFile, { force: true }))
  state.approvals.delete(id)
  pending.owner.delete(id)
}

function closeForSession(sessionID: string) {
  for (const [id, pending] of state.approvals) {
    if (pending.sessionID === sessionID || rootOf(pending.sessionID) === sessionID) closeApproval(id)
  }
}

/// OpenCode sends no reply event for a request whose session stops, so a subagent's open
/// requests are reported as withdrawn on the root; a root's own end clears them in Pitwall.
function settleAsks(sessionID: string, rootID: string, cwd: string | undefined) {
  for (const [id, ask] of state.asks) {
    if (ask.sessionID !== sessionID && rootOf(ask.sessionID) !== sessionID) continue
    state.asks.delete(id)
    if (sessionID !== rootID) {
      emit(ask.form ? "form.cancelled" : "permission.replied", rootID, cwd, { request_id: id, reason: "withdrawn" })
    }
  }
}

function openApproval(ctx: any, event: Event, sessionID: string, rootID: string, cwd: string | undefined, owned: Set<string>) {
  const data = event.data ?? {}
  const requestID = data.id
  const action = data.action
  if (typeof requestID !== "string" || typeof action !== "string") return
  const id = safeID(requestID) ? requestID : `${Math.floor(Date.now() / 1000)}-${process.pid}-${++state.counter}`
  if (!safeID(rootID) || !safeID(id)) return
  const resource = Array.isArray(data.resources) ? data.resources.filter((item: unknown) => typeof item === "string") : []
  const message = typeof data.message === "string" ? data.message : undefined
  const rawInput = action === "shell"
    ? { command: resource.join("\n") }
    : { prompt: message ?? `${action}: ${resource.join(", ")}` }
  const serialized = JSON.stringify(rawInput)
  const toolInput = serialized.length > 4000 ? { _truncated: serialized.slice(0, 4000) } : rawInput
  const filename = `opencode.${rootID}.${action.replace(/[^A-Za-z0-9_.-]/g, "_")}.${id}.json`
  const requestFile = join(APPROVALS, "requests", filename)
  const decisionFile = join(APPROVALS, "decisions", id)
  const written = attempt(() => {
    mkdirSync(join(APPROVALS, "requests"), { recursive: true })
    mkdirSync(join(APPROVALS, "decisions"), { recursive: true })
    chmodSync(APPROVALS, 0o700)
    writeFileSync(`${requestFile}.tmp`, JSON.stringify({
      v: 1, id, agent: "opencode", created_at: Date.now() / 1000, pid: process.pid,
      session_id: rootID, cwd, tool_name: action, tool_input: toolInput,
    }))
    renameSync(`${requestFile}.tmp`, requestFile)
    return true
  })
  if (!written) {
    attempt(() => rmSync(`${requestFile}.tmp`, { force: true }))
    return
  }
  const started = Date.now()
  const timer = setInterval(() => {
    if (attempt(() => existsSync(requestFile)) !== true || !listening() || Date.now() - started >= LIMIT_MS) {
      closeApproval(requestID)
      return
    }
    const decision = attempt(() => existsSync(decisionFile) ? readFileSync(decisionFile, "utf8").trim() : undefined)
    if (decision === undefined) return
    closeApproval(requestID)
    if (decision !== "allow" && decision !== "deny") return
    attempt(() => Promise.resolve(ctx.permission.reply({
      sessionID, requestID, decision: decision === "allow" ? "once" : "reject",
    })).catch(() => {}))
  }, 200)
  attempt(() => timer.unref())
  state.approvals.set(requestID, { requestID, sessionID, owner: owned, requestFile, decisionFile, timer })
  owned.add(requestID)
}

function handle(ctx: any, event: Event, owned: Set<string>) {
  const data = event.data ?? {}
  const type = event.type ?? ""
  const sessionID = sessionOf(event)
  if (typeof event.id !== "string") return

  // A session first seen mid-stream (created before this server loaded the plugin, or by a
  // location whose instance started later) waits for its parent, so a subagent never shows
  // up as a session of its own. While it is looked up, every event of it waits, its creation
  // included, so none overtakes the ones already waiting.
  if (typeof sessionID === "string" &&
    (state.resolving.has(sessionID) || (type !== "session.created" && !state.known.has(sessionID)))) {
    const queue = state.deferred.get(sessionID) ?? []
    queue.push({ ctx, event, owned })
    state.deferred.set(sessionID, queue)
    void resolve(sessionID, ctx)
    return
  }
  if (typeof sessionID === "string") touch(sessionID)
  const first = claim(event.id)

  if (type === "permission.asked") {
    if (typeof sessionID !== "string") return
    const rootID = rootOf(sessionID)
    const cwd = state.cwd.get(sessionID) ?? state.cwd.get(rootID) ?? event.location?.directory
    const directory = event.location?.directory ?? state.cwd.get(rootID)
    if (first) {
      if (typeof data.id === "string") state.asks.set(data.id, { sessionID, form: false })
      emit(type, rootID, cwd, {
        request_id: data.id, tool_name: data.action,
        title: firstLine((Array.isArray(data.resources) ? data.resources[0] : undefined) ?? data.message, TITLE_LIMIT),
      })
    }
    // A replayed event may come from an instance stopped meanwhile; only a running one can answer.
    if (state.contexts.has(ctx) && (!directory || ctx.location?.directory === directory) && listening() &&
      claim(`approval:${event.id}`)) {
      openApproval(ctx, event, sessionID, rootID, cwd, owned)
    }
    return
  }
  if (!first) return

  if (type === "session.created" && typeof sessionID === "string") {
    learn(sessionID, data.location?.directory ?? event.location?.directory, data.parentID)
    if (typeof data.parentID !== "string") emit(type, sessionID, state.cwd.get(sessionID))
    return
  }

  if (typeof sessionID !== "string") return
  const rootID = rootOf(sessionID)
  const cwd = state.cwd.get(sessionID) ?? state.cwd.get(rootID) ?? event.location?.directory
  const child = rootID !== sessionID

  if (type.startsWith("session.execution.") || type === "session.deleted" || type === "session.archived") {
    closeForSession(sessionID)
    settleAsks(sessionID, rootID, cwd)
    state.tools.delete(sessionID)
  }
  if (child && (type.startsWith("session.execution.") || type === "session.deleted" || type === "session.archived")) {
    if (type === "session.deleted" || type === "session.archived") forgetTree(sessionID)
    return
  }

  if (type === "session.inbox.enqueued") {
    if (!child && data.item?.type === "user" && typeof data.item.payload?.text === "string") {
      const queue = state.prompts.get(sessionID) ?? []
      queue.push({ inboxID: data.inboxID, text: data.item.payload.text })
      state.prompts.set(sessionID, queue)
    }
    return
  }
  if (type === "session.inbox.delivered") {
    if (!child) {
      const queue = state.prompts.get(sessionID) ?? []
      state.prompts.set(sessionID, queue.filter((item) => item.inboxID !== data.inboxID))
    }
    return
  }

  if (type === "permission.replied") {
    if (typeof data.requestID === "string") {
      closeApproval(data.requestID)
      state.asks.delete(data.requestID)
    }
    emit(type, rootID, cwd, { request_id: data.requestID, reason: data.reply })
    return
  }
  if (type === "form.created") {
    const form = data.form ?? {}
    if (typeof form.id === "string") state.asks.set(form.id, { sessionID, form: true })
    emit(type, rootID, cwd, {
      request_id: form.id,
      title: firstLine(form.fields?.[0]?.description ?? form.fields?.[0]?.title ?? form.title, TITLE_LIMIT),
    })
    return
  }
  if (type === "form.replied" || type === "form.cancelled") {
    if (typeof data.id === "string") state.asks.delete(data.id)
    emit(type, rootID, cwd, { request_id: data.id })
    return
  }

  if (child) return
  if (type === "session.tool.input.started" && typeof data.id === "string" && typeof data.name === "string") {
    const tools = state.tools.get(sessionID) ?? new Map()
    tools.set(data.id, data.name)
    state.tools.set(sessionID, tools)
    return
  }
  if (type === "session.text.ended") {
    const reply = excerpt(data.text, REPLY_LIMIT)
    if (reply) state.replies.set(sessionID, reply)
    return
  }
  if (type.startsWith("session.execution.")) {
    if (type === "session.execution.started") {
      state.replies.delete(sessionID)
      const prompt = state.prompts.get(sessionID)?.[0]?.text
      emit(type, rootID, cwd, { ...(prompt ? { prompt_head: firstLine(prompt, PROMPT_LIMIT) } : {}) })
    } else if (type === "session.execution.succeeded") {
      emit(type, rootID, cwd, { ...(state.replies.get(sessionID) ? { reply_head: state.replies.get(sessionID) } : {}) })
    } else if (type === "session.execution.failed") {
      emit(type, rootID, cwd, { error: cut(data.error?.message, 200) })
    } else if (type === "session.execution.interrupted") {
      emit(type, rootID, cwd, { reason: data.reason })
    }
    return
  }
  if (type === "session.tool.called") {
    const toolName = state.tools.get(sessionID)?.get(data.id)
    if (toolName) emit(type, rootID, cwd, { tool_name: toolName })
    state.tools.get(sessionID)?.delete(data.id)
    return
  }
  if (type === "session.deleted" || type === "session.archived") {
    emit(type, sessionID, cwd)
    forgetTree(sessionID)
  }
}

export default {
  id: "pitwall",
  setup: async (ctx: any) => {
    const owned = new Set<string>()
    const controller = new AbortController()
    state.contexts.add(ctx)
    const subscription = (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        attempt(() => handle(ctx, event, owned))
      }
    })()
    void subscription.catch(() => {})
    return async () => {
      controller.abort()
      state.contexts.delete(ctx)
      for (const id of [...owned]) closeApproval(id)
      await subscription.catch(() => {})
    }
  },
}
