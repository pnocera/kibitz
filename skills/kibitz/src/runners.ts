// Advisor process boundary. A runner receives bounded, already-rendered input
// and returns only schema data; it never shares the observed host session.

import { spawnSync } from "node:child_process"
import * as fs from "node:fs"
import * as path from "node:path"
import { CLAUDE_TIMEOUT, CODEX_TIMEOUT, Host, SCHEMA, appendSync, read, which } from "./core.ts"
import { adapterFor } from "./hosts.ts"

export interface RunResult {
  ok: boolean
  advisories: any[]
  error?: string
}

const maxCycles = () => {
  const n = Number(process.env.ADVISOR_MAX_CYCLES ?? "0")
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0
}

/** The worker holds the per-session lock, so this append is a durable
 * reservation, not a racy estimate. Failed reservations fail closed. */
export function reserveCycle(sessionDir: string, host: Host): boolean {
  const cap = maxCycles()
  if (cap === 0) return true
  const file = path.join(sessionDir, `budget-${host}`)
  const used = (read(file) ?? "").split("\n").filter(Boolean).length
  if (used >= cap) return false
  return appendSync(file, `${Date.now()}\n`)
}

const parseCodex = (raw: string): RunResult => {
  try {
    const advisories = JSON.parse(raw).advisories
    return Array.isArray(advisories) ? { ok: true, advisories } : { ok: false, advisories: [], error: "Codex output has no advisories array" }
  } catch { return { ok: false, advisories: [], error: "Codex output is not JSON" } }
}

const parseClaude = (raw: string): RunResult => {
  try {
    const envelope = JSON.parse(raw)
    if (envelope?.is_error === true) return { ok: false, advisories: [], error: String(envelope.result ?? "Claude reported an error") }
    if (envelope?.subtype !== "success") return { ok: false, advisories: [], error: `Claude subtype: ${String(envelope?.subtype ?? "missing")}` }
    const advisories = envelope?.structured_output?.advisories
    return Array.isArray(advisories) ? { ok: true, advisories } : { ok: false, advisories: [], error: "Claude output has no structured advisories array" }
  } catch { return { ok: false, advisories: [], error: "Claude output is not JSON" } }
}

export function invokeRunner(host: Host, cwd: string, prompt: string, outputFile: string, logPath: string): RunResult {
  const adapter = adapterFor(host)
  const runDir = path.dirname(outputFile)
  const schema = read(SCHEMA)
  if (!schema) return { ok: false, advisories: [], error: `missing schema ${SCHEMA}` }
  let outFd: number | undefined
  let logFd: number | undefined
  try {
    outFd = fs.openSync(outputFile, "w")
    logFd = fs.openSync(logPath, "a")
    if (adapter.advisor === "codex") {
      const result = spawnSync("timeout", [String(CODEX_TIMEOUT), "codex", "exec",
        "--sandbox", "read-only", "--cd", cwd, "--skip-git-repo-check",
        "--output-schema", SCHEMA, "-o", outputFile, "-"], {
        input: prompt,
        stdio: ["pipe", logFd, logFd],
        env: { ...process.env, KIBITZ_ADVISOR: "1" },
      })
      const raw = read(outputFile) ?? ""
      if (result.status !== 0) return { ok: false, advisories: [], error: `Codex exited ${result.status}` }
      return parseCodex(raw)
    }
    if (process.platform !== "linux" || !which("bwrap") || !which("claude"))
      return { ok: false, advisories: [], error: "Claude advisor needs Linux, bwrap, and claude" }
    const result = spawnSync("timeout", [String(CLAUDE_TIMEOUT), "bwrap",
      "--die-with-parent", "--ro-bind", "/", "/", "--bind", runDir, runDir,
      "--dev-bind", "/dev", "/dev", "--proc", "/proc", "--share-net",
      "--setenv", "KIBITZ_ADVISOR", "1", "--",
      "claude", "--print", "--output-format", "json", "--json-schema", schema,
      "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "-"], {
      input: prompt,
      stdio: ["pipe", outFd, logFd],
      env: { ...process.env, KIBITZ_ADVISOR: "1", KIBITZ_RUN_DIR: runDir },
    })
    const raw = read(outputFile) ?? ""
    if (result.status !== 0) return { ok: false, advisories: [], error: `Claude exited ${result.status}` }
    return parseClaude(raw)
  } catch (error) {
    return { ok: false, advisories: [], error: (error as Error).message }
  } finally {
    if (outFd !== undefined) try { fs.closeSync(outFd) } catch {}
    if (logFd !== undefined) try { fs.closeSync(logFd) } catch {}
  }
}
