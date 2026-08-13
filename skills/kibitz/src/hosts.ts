// Host-specific parsing and activity classification. Queue state stays host
// neutral; only the protocol at the host edge belongs here.

import * as fs from "node:fs"
import { ACTIVITY_LINES, SENTINEL, TRANSCRIPT_LINES, Host, OperationPhase, exists } from "./core.ts"

export interface Context { activity: string; goal: string }

export interface Observation {
  at?: string; tool: string; command_class: string; input: string
  local_exit?: number; remote_transport: "not_remote" | "received" | "unknown"
  output: "complete" | "incomplete"; elapsed_ms?: number; changed_state: boolean; error?: string
}

const redact = (s: string) => s
  .replace(/(password|token|secret|api[_-]?key)\s*[=:]\s*([^\s,;]+)/ig, "$1=[redacted]")
  .replace(/(https?:\/\/)[^\s/@:]+:[^\s/@]+@/ig, "$1[redacted]@")

export function commandClass(tool: string, input: string): string {
  const c = `${tool} ${input}`.toLowerCase()
  if (/\bssh\b|\bscp\b|\brsync\b/.test(c)) return "remote_shell"
  if (/systemctl|journalctl|systemd/.test(c)) return "systemd"
  if (/psql|postgres|\bsql\b/.test(c)) return "database"
  if (/git\s+(status|diff|log|show)/.test(c)) return "inspect"
  if (/sleep|watch|tail\s+-f/.test(c)) return "monitor"
  if (/curl|wget|http/.test(c)) return "network"
  return tool || "unknown"
}

export function observeEvent(e: any): Observation {
  const rawInput = e?.input ?? e?.tool_input ?? ""
  const input = redact(typeof rawInput === "string" ? rawInput : JSON.stringify(rawInput)).slice(0, 800)
  const exitRaw = e?.local_exit ?? e?.tool_response?.exit_code ?? e?.tool_response?.exitCode ?? e?.exit_code
  const local_exit = Number.isFinite(Number(exitRaw)) ? Number(exitRaw) : undefined
  const klass = e?.command_class ?? commandClass(String(e?.tool ?? e?.tool_name ?? ""), input)
  const remote = klass === "remote_shell"
    ? (Number.isFinite(Number(e?.remote_exit ?? e?.remote_exit_code)) ? "received" : "unknown") : "not_remote"
  const clipped = e?.truncated === true || e?.output_truncated === true || /\b(truncated|clipped)\b/i.test(String(e?.error ?? ""))
  return {
    at: typeof e?.at === "string" ? e.at : undefined,
    tool: String(e?.tool ?? e?.tool_name ?? ""), command_class: klass, input,
    ...(local_exit === undefined ? {} : { local_exit }), remote_transport: remote,
    output: clipped ? "incomplete" : "complete",
    ...(Number.isFinite(Number(e?.elapsed_ms)) ? { elapsed_ms: Number(e.elapsed_ms) } : {}),
    changed_state: Boolean(e?.changed_state ?? /\b(edit|write|apply_patch|restart|start|stop|enable|disable|deploy|rm\b)/i.test(`${e?.tool ?? ""} ${input}`)),
    ...(e?.error ? { error: redact(String(e.error)).slice(0, 400) } : {}),
  }
}

export function inferPhase(observations: Observation[]): OperationPhase {
  const last = observations[observations.length - 1]
  if (!last) return "unknown"
  const text = `${last.command_class} ${last.input}`.toLowerCase()
  if (/restore|unpause|enable.*timer|start.*timer/.test(text)) return "restore"
  if (last.changed_state) return "mutate"
  if (/monitor|wait|is-active|journalctl|status/.test(text)) return "wait_monitor"
  if (/verify|test|check|show/.test(text)) return "verify"
  if (/diagnos|database|network|remote_shell/.test(text)) return "diagnose"
  if (/inspect|read|grep|glob|diff/.test(text)) return "inspect"
  return "unknown"
}

export const renderFacts = (observations: Observation[]): string => observations.slice(-12).map(o => {
  const local = o.local_exit === undefined ? "local exit unknown" : `local exit ${o.local_exit}`
  const remote = o.remote_transport === "unknown" ? "; remote transport unknown" : o.remote_transport === "received" ? "; remote result received" : ""
  const clip = o.output === "incomplete" ? "; output incomplete" : ""
  const fromDb = /--from-db\b/.test(o.input) ? "; from-db mode: do not infer an embedding launch from this command" : ""
  return `${o.at ?? "now"} ${o.command_class}: ${local}${remote}${clip}${fromDb}${o.changed_state ? "; changed state" : ""}${o.error ? `; error ${o.error}` : ""}`
}).join("\n") || "(no new structured facts)"

export interface HostAdapter {
  readonly host: Host
  readonly advisor: "codex" | "claude"
  readonly advisorLabel: "Codex" | "Claude"
  isNavigation(tool: string): boolean
  readContext(transcript: string): Context
}

function readTailLines(file: string, maxLines: number): string[] {
  const fd = fs.openSync(file, "r")
  try {
    const size = fs.fstatSync(fd).size
    const cap = 1 << 26
    const chunk = 1 << 16
    const parts: Buffer[] = []
    let pos = size
    let newlines = 0
    let held = 0
    while (pos > 0 && newlines <= maxLines && held < cap) {
      const len = Math.min(chunk, pos)
      pos -= len
      const b = Buffer.alloc(len)
      fs.readSync(fd, b, 0, len, pos)
      parts.unshift(b)
      held += len
      for (const byte of b) if (byte === 10) newlines++
    }
    return Buffer.concat(parts).toString("utf8").split("\n").filter(Boolean).slice(-maxLines)
  } finally { try { fs.closeSync(fd) } catch {} }
}

const textParts = (content: any): string[] => {
  const values = Array.isArray(content) ? content : [content]
  const out: string[] = []
  for (const value of values) {
    if (typeof value === "string") out.push(value)
    else if (value?.type === "text" || value?.type === "input_text" || value?.type === "output_text")
      out.push(String(value.text ?? value.value ?? ""))
    else if (value?.type === "tool_use" || value?.type === "function_call")
      out.push(`→ ${value.name ?? value.function?.name ?? "tool"}: ${JSON.stringify(value.input ?? value.arguments ?? {}).slice(0, 200)}`)
  }
  return out
}

function claudeContext(transcript: string): Context {
  if (!transcript || !exists(transcript)) return { activity: "(transcript unavailable)", goal: "(unknown)" }
  let lines: string[]
  try { lines = readTailLines(transcript, TRANSCRIPT_LINES) } catch { return { activity: "(transcript unreadable)", goal: "(unknown)" } }
  const activity: string[] = []
  let goal = "(unknown)"
  for (const line of lines) {
    let item: any
    try { item = JSON.parse(line) } catch { continue }
    if (item?.isSidechain === true || !item?.message) continue
    const content = item.message.content ?? []
    const text = textParts(content).join("\n")
    if (!text) continue
    if (item.message.role === "user") {
      const plain = textParts(content).filter(x => !x.startsWith("→ ")).join(" ").trim()
      if (plain) goal = plain.slice(0, 800)
    }
    if (!text.includes(SENTINEL)) activity.push(`[${item.message.role}] ${text.slice(0, 600)}`)
  }
  return { activity: activity.slice(-40).join("\n\n").split("\n").slice(-ACTIVITY_LINES).join("\n"), goal }
}

/** Codex rollout JSONL is not Claude's message schema. Read only stable text
 * fields from common event envelopes; unknown records remain visible as no
 * activity rather than being decoded with the Claude parser. */
function codexContext(transcript: string): Context {
  if (!transcript || !exists(transcript)) return { activity: "(transcript unavailable)", goal: "(unknown)" }
  let lines: string[]
  try { lines = readTailLines(transcript, TRANSCRIPT_LINES) } catch { return { activity: "(transcript unreadable)", goal: "(unknown)" } }
  const activity: string[] = []
  let goal = "(unknown)"
  for (const line of lines) {
    let item: any
    try { item = JSON.parse(line) } catch { continue }
    const payload = item?.payload ?? item?.event ?? item
    const role = payload?.role ?? payload?.message?.role ?? item?.role ?? item?.type ?? "event"
    if (role === "developer") continue
    if (payload?.type === "custom_tool_call" || payload?.type === "custom_tool_call_output") {
      const name = payload?.name ?? "tool"
      const value = payload?.input ?? payload?.output ?? payload?.result ?? {}
      activity.push(`→ ${name}: ${JSON.stringify(value).slice(0, 200)}`)
      continue
    }
    const content = payload?.content ?? payload?.message?.content ?? payload?.text ?? item?.text
    const text = textParts(content).join("\n")
    if (!text || text.includes(SENTINEL)) continue
    if (role === "user" || item?.type === "user_message") goal = text.slice(0, 800)
    activity.push(`[${role}] ${text.slice(0, 600)}`)
  }
  return { activity: activity.slice(-40).join("\n\n").split("\n").slice(-ACTIVITY_LINES).join("\n"), goal }
}

const claudeNavigation = new Set([
  "Read", "Glob", "Grep", "TodoWrite", "NotebookRead",
  "WebFetch", "WebSearch", "ListMcpResources", "Task",
])
// Codex 0.147 emits these names at the hook boundary. A shell command is not
// listed because it can mutate state even when its text looks read-only.
const codexNavigation = new Set(["read_file", "web_search", "view_image", "update_plan", "Read", "Grep", "Glob"])

export const adapterFor = (host: Host): HostAdapter => host === "codex"
  ? { host, advisor: "claude", advisorLabel: "Claude", isNavigation: tool => codexNavigation.has(tool), readContext: codexContext }
  : { host, advisor: "codex", advisorLabel: "Codex", isNavigation: tool => claudeNavigation.has(tool), readContext: claudeContext }
