import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// Runs inside each OpenCode terminal client. The server plugin cannot know which terminal shows a
// session, so every client publishes what it shows, and Pitwall asks a client to switch sessions.
const HOME = process.env.PITWALL_HOME || join(homedir(), ".pitwall")
const CLIENTS = join(HOME, "opencode", "clients")
const FOCUS = join(HOME, "opencode", "focus")
const POLL_MS = 300
const SAFE = /^[A-Za-z0-9_.-]{1,128}$/

function attempt<T>(fn: () => T): T | undefined {
  try {
    return fn()
  } catch {
    return undefined
  }
}

function rootOf(ctx: any, sessionID: string): string {
  const root = attempt(() => ctx.data.session.root(sessionID))
  return typeof root === "string" && root ? root : sessionID
}

/// The root sessions this client shows and has open as tabs; Pitwall lists root sessions only.
function snapshot(ctx: any, started: number) {
  const route = attempt(() => ctx.ui.router.current())
  const current = route?.type === "session" && typeof route.sessionID === "string" ? rootOf(ctx, route.sessionID) : null
  const tabs = attempt(() => ctx.ui.tabs.enabled() ? ctx.ui.tabs.list() : []) ?? []
  return {
    v: 1,
    pid: process.pid,
    started,
    terminal: process.env.TERM_PROGRAM ?? null,
    cwd: ctx.location?.directory ?? process.cwd(),
    current,
    tabs: [...new Set(tabs.map((tab: any) => tab?.sessionID).filter((id: unknown) => typeof id === "string")
      .map((id: string) => rootOf(ctx, id)))],
  }
}

/// A focus request is the session ID Pitwall wants this client to show.
function takeFocus(file: string): string | undefined {
  const value = attempt(() => readFileSync(file, "utf8").trim())
  if (value === undefined) return undefined
  attempt(() => rmSync(file, { force: true }))
  return SAFE.test(value) ? value : undefined
}

function focus(ctx: any, sessionID: string) {
  const tabs = attempt(() => ctx.ui.tabs.enabled()) === true
  if (tabs && attempt(() => ctx.ui.tabs.focus(sessionID)) === true) return
  attempt(() => ctx.ui.router.navigate({ type: "session", sessionID }))
}

export default {
  id: "pitwall",
  setup(ctx: any) {
    const started = Math.round(Date.now() - process.uptime() * 1000)
    const clientFile = join(CLIENTS, `${process.pid}.json`)
    const focusFile = join(FOCUS, String(process.pid))
    let written = ""
    // A request left for an earlier process with this pid is not for this client.
    attempt(() => rmSync(focusFile, { force: true }))
    const tick = () => {
      const sessionID = takeFocus(focusFile)
      if (sessionID) focus(ctx, sessionID)
      const text = JSON.stringify(snapshot(ctx, started))
      if (text === written) return
      const saved = attempt(() => {
        mkdirSync(CLIENTS, { recursive: true })
        writeFileSync(`${clientFile}.tmp`, text)
        renameSync(`${clientFile}.tmp`, clientFile)
        return true
      })
      if (saved) written = text
    }
    tick()
    const timer = setInterval(() => attempt(tick), POLL_MS)
    attempt(() => timer.unref())
    const remove = () => {
      attempt(() => rmSync(clientFile, { force: true }))
      attempt(() => rmSync(focusFile, { force: true }))
    }
    process.once("exit", remove)
    return () => {
      clearInterval(timer)
      process.off("exit", remove)
      remove()
    }
  },
}
