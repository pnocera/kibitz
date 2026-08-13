// Operator-facing commands. Output strings are part of the contract: the test
// suite asserts on them, and several are the only thing telling someone which
// command to type next.

import { spawn, spawnSync } from "node:child_process"
import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"
import {
  BIN, HOME, OURS_RE, PROMPT_TMPL, SCHEMA,
  appendSync, currentHost, currentSession, deliveredCount, ensureHostRoot, epochOf, exists, isEnabled, isoNow, issueStateMap, listJson, mkdirp, outcomeMap, projDir, read, readIssueEvents, readIssues,
  killTree, readState, rm, sessDir, verifiedWorkerPid, which, writeState,
} from "./core.ts"
import { adapterFor } from "./hosts.ts"

const out = (s: string) => process.stdout.write(s + "\n")
const err = (s: string) => process.stderr.write(s + "\n")

export function cmdOn(cwd = process.cwd()): number {
  if (!writeState(cwd, true)) {
    err(`kibitzer: state root belongs to another host: ${currentHost()}`)
    return 1
  }
  const p = projDir(cwd)
  mkdirp(path.join(p, "sessions"))
  try { fs.writeFileSync(path.join(p, "cwd"), cwd + "\n") } catch {}
  rm(path.join(p, "quiet"))
  out(`kibitzer: on for ${cwd} (${currentHost()} host)`)
  out(`  state: ${p}`)
  out("  log:   kibitzer tail   (or: kibitzer pane, for a Herdr side pane)")
  return 0
}

export function cmdOff(cwd = process.cwd()): number {
  if (!writeState(cwd, false)) {
    err(`kibitzer: state root belongs to another host: ${currentHost()}`)
    return 1
  }
  const p = projDir(cwd)
  mkdirp(p)
  // Bump first: everything queued, and everything an in-flight producer is
  // about to write, belongs to the old epoch and is inert from this instant.
  rm(path.join(p, "enabled"))       // legacy flag: never let migration resurrect it

  let killed = 0
  const sessions = path.join(p, "sessions")
  let dirs: string[] = []
  try { dirs = fs.readdirSync(sessions) } catch {}
  for (const s of dirs) {
    const pidf = path.join(sessions, s, "worker.pid")
    const pid = verifiedWorkerPid(pidf)
    if (pid !== null) { killTree(pid); killed++ }
    rm(pidf)
    // Housekeeping only. Anything this misses -- or that an unreapable worker
    // writes a moment from now -- carries the old epoch and will never be read.
    for (const q of ["outbox", "outbox-processing", "events", "events-processing"])
      for (const f of listJson(path.join(sessions, s, q))) rm(f)
  }
  out(`kibitzer: off for ${cwd} (${currentHost()} host; reaped ${killed} in-flight, cleared pending advisories)`)
  return 0
}

export function cmdQuiet(mode = "on", cwd = process.cwd()): number {
  if (!ensureHostRoot()) { err(`kibitzer: state root belongs to another host: ${currentHost()}`); return 1 }
  const p = projDir(cwd)
  mkdirp(p)
  if (mode === "on") {
    try { fs.writeFileSync(path.join(p, "quiet"), "") } catch {}
    out("kibitzer: quiet — still analysing and logging, not injecting")
  } else if (mode === "off") {
    rm(path.join(p, "quiet"))
    out("kibitzer: quiet off — injecting again")
  } else { err("usage: kibitzer quiet on|off"); return 2 }
  return 0
}

export function cmdStatus(cwd = process.cwd()): number {
  const p = projDir(cwd)
  process.stdout.write(`kibitzer  ${cwd}  (${currentHost()} host)\n`)
  process.stdout.write(`  enabled : ${isEnabled(cwd) ? "yes" : "no  (kibitzer on)"}\n`)
  process.stdout.write(`  quiet   : ${exists(path.join(p, "quiet")) ? "yes" : "no"}\n`)
  if (!exists(p)) { process.stdout.write("  state   : none yet\n"); return 0 }
  const sid = currentSession(cwd)
  if (!sid) { process.stdout.write("  session : none seen yet\n"); return 0 }
  const d = sessDir(cwd, sid)
  const pending = listJson(path.join(d, "outbox"))
  process.stdout.write(`  session : ${sid}\n`)
  process.stdout.write(`  pending : ${pending.length} advisories waiting\n`)
  // "claimed", not "emitted": both consumers commit the marker BEFORE their
  // final off/epoch check, so an advisory that `off` catches in that window is
  // counted here and never shown. The channel has no acknowledgement either, so
  // no record we hold can honestly claim the operator saw anything. Markers and
  // ledger lines together: on a session upgraded from the ledger-only version,
  // either record alone is a partial count.
  process.stdout.write(`  claimed : ${deliveredCount(d)} advisories committed for delivery\n`)
  process.stdout.write(`  advisor : ${adapterFor(currentHost()).advisorLabel} ${verifiedWorkerPid(path.join(d, "worker.pid")) ? "running" : "idle"}\n`)
  const stuck = pending.filter(f => {
    try { return Date.now() - fs.statSync(f).mtimeMs > 3 * 60000 } catch { return false }
  }).length
  if (stuck > 0) {
    process.stdout.write(`  \x1b[33m${stuck} advisories have been queued over 3 minutes\x1b[0m\n`)
    process.stdout.write("    they are only delivered on a tool call, so this is normal while idle.\n")
  }
  process.stdout.write(`  log     : ${path.join(d, "advice.log")}\n`)
  const lastErr = read(path.join(d, "last-error"))
  if (lastErr && lastErr.trim() !== "") {
    process.stdout.write("  \x1b[31mlast cycle failed\x1b[0m\n")
    for (const l of lastErr.replace(/\n$/, "").split("\n")) process.stdout.write(`    ${l}\n`)
    process.stdout.write(`    full detail: ${path.join(d, "worker.log")}\n`)
  }
  return 0
}

/** Pending count for the statusline. Silent on any error, never non-zero. */
export function cmdCount(cwd = process.cwd()): number {
  if (!isEnabled(cwd)) { process.stdout.write("0"); return 0 }
  const sid = currentSession(cwd)
  if (!sid) { process.stdout.write("0"); return 0 }
  process.stdout.write(String(listJson(path.join(sessDir(cwd, sid), "outbox")).length))
  return 0
}

export function cmdStatusline(cwd = process.cwd()): number {
  const sid = isEnabled(cwd) ? currentSession(cwd) : null
  const n = sid ? listJson(path.join(sessDir(cwd, sid), "outbox")).length : 0
  if (n > 0) process.stdout.write(`\x1b[38;5;179m◈ ${n}\x1b[0m`)
  return 0
}

const curLog = (cwd: string): string | null => {
  const sid = currentSession(cwd)
  return sid ? path.join(sessDir(cwd, sid), "advice.log") : null
}

export function cmdTail(cwd = process.cwd()): number {
  const f = curLog(cwd)
  if (!f) { err("kibitzer: no session yet"); return 1 }
  const r = spawnSync("tail", ["-f", f], { stdio: "inherit" })
  return r.status ?? 0
}

export function cmdLog(cwd = process.cwd(), n = "60"): number {
  const f = curLog(cwd)
  if (!f) { err("kibitzer: no session yet"); return 1 }
  const body = read(f) ?? ""
  if (body.trim() === "") { out("kibitzer: nothing said yet"); return 0 }
  const lines = body.replace(/\n$/, "").split("\n")
  out(lines.slice(-Number(n)).join("\n"))
  return 0
}

export function cmdPane(cwd = process.cwd()): number {
  if (!which("herdr")) { err("kibitzer: herdr not found"); return 1 }
  if (!curLog(cwd)) { err("kibitzer: no session yet — run a turn first"); return 1 }
  const r = spawnSync("herdr",
    ["pane", "split", "--current", "--direction", "right", "--ratio", "0.3", "--no-focus"],
    { encoding: "utf8" })
  if (r.status !== 0) {
    err(`kibitzer: could not split (${(r.stderr || r.stdout || "").trim()})`)
    err("  run this in any terminal instead:")
    err(`    ${BIN} tail ${cwd}`)
    return 1
  }
  // herdr wraps replies as {"id":"cli:pane:split","result":{"pane":{...}}} --
  // the top-level "id" is the request id and the pane id is nested. Never fall
  // back to scraping the blob: that yields a garbage id which is then handed to
  // `herdr pane run`, failing confusingly instead of saying what went wrong.
  let pane = ""
  try {
    const j = JSON.parse(r.stdout)
    pane = j?.result?.pane?.pane_id ?? j?.result?.pane_id ?? j?.pane_id ?? ""
  } catch {}
  if (!pane) {
    err("kibitzer: could not read a pane id from herdr")
    err(`  reply: ${r.stdout.trim()}`)
    return 1
  }
  spawnSync("herdr", ["pane", "rename", pane, "kibitz"], { stdio: "ignore" })
  const run = spawnSync("herdr", ["pane", "run", pane, BIN, "tail", cwd], { stdio: "ignore" })
  if (run.status !== 0) { err(`kibitzer: pane ${pane} opened but the tail did not start`); return 1 }
  out(`kibitzer: following the log in pane ${pane}`)
  return 0
}

/** Nothing on any output path may read as a review gate. */
export function cmdLint(target?: string): number {
  if (!target || !exists(target)) { err("usage: kibitzer lint <file>"); return 2 }
  const pat = /VERDICT|FIXES_REQUIRED|\bBLOCKER\b|\bNIT\b|severity|PASS\/FAIL|approved|rejected|sign-?off/i
  const lines = (read(target) ?? "").split("\n")
  let bad = false
  lines.forEach((l, i) => { if (pat.test(l)) { out(`${i + 1}:${l}`); bad = true } })
  if (bad) { err(`kibitzer lint: gate language found in ${target}`); return 1 }
  out("kibitzer lint: clean")
  return 0
}

export function cmdMute(arg?: string, cwd = process.cwd()): number {
  const p = projDir(cwd)
  if (arg === "list") {
    const m = read(path.join(p, "mutes"))
    if (m && m.trim() !== "") process.stdout.write(m.endsWith("\n") ? m : m + "\n")
    else out("kibitzer: nothing muted")
    return 0
  }
  if (arg === "clear") { rm(path.join(p, "mutes")); out("kibitzer: mutes cleared"); return 0 }
  if (!arg) { err("usage: kibitzer mute <text> | list | clear"); return 2 }
  if (!ensureHostRoot()) { err(`kibitzer: state root belongs to another host: ${currentHost()}`); return 1 }
  mkdirp(p)
  try { fs.appendFileSync(path.join(p, "mutes"), arg + "\n") } catch {}
  out(`kibitzer: muting advisories matching '${arg}'`)
  return 0
}

const OUTCOMES = ["accepted", "investigated", "declined", "superseded"]

/** Record what an advisory led to. The advisor cannot observe this and must not
 *  guess it: an outcome is written only when someone says so, and everything
 *  unmarked is reported as unmarked rather than counted as anything. */
export function cmdMark(idPrefix?: string, outcome?: string, a?: string, b?: string): number {
  if (!idPrefix || !outcome || !OUTCOMES.includes(outcome)) {
    err(`usage: kibitzer mark <id> accepted|investigated|declined [cwd]`)
    err(`       kibitzer mark <id> superseded <id it duplicates> [cwd]`)
    return 2
  }
  // Only `superseded` names another advisory, so only there is the third word an
  // id. Consuming it unconditionally made the ordinary `mark <id> accepted /repo`
  // read the directory as an id and fail.
  const by = outcome === "superseded" ? a : undefined
  const cwd = (outcome === "superseded" ? b : a) || process.cwd()
  if (outcome === "superseded" && !by) {
    err("usage: kibitzer mark <id> superseded <id it duplicates> [cwd]"); return 2
  }
  const sid = currentSession(cwd)
  if (!sid) { err("kibitzer: no session yet"); return 1 }
  const d = sessDir(cwd, sid)
  const hits = readIssues(d).filter(i => i.id.startsWith(idPrefix))
  // Nothing is written for an id we cannot resolve. A mark landing on the wrong
  // advisory is worse than one that did not land: the record is the evidence.
  if (hits.length === 0) { err(`kibitzer: no advisory here starts with '${idPrefix}'`); return 1 }
  if (hits.length > 1) {
    // Full ids, not a longer prefix: the log shows six characters and nothing
    // else exposes more, so telling an operator to "type more" of something they
    // cannot see is a dead end. These are the values to paste.
    err(`kibitzer: '${idPrefix}' matches ${hits.length} advisories. Use one of:`)
    for (const h of hits) err(`    ${h.id}`)
    return 1
  }
  let byId: string | undefined
  if (by !== undefined && by !== "") {
    const target = readIssues(d).filter(i => i.id.startsWith(by))
    if (target.length !== 1) { err(`kibitzer: '${by}' does not name exactly one advisory`); return 1 }
    byId = target[0]!.id
  }
  const ev = { id: hits[0]!.id, outcome, ...(byId ? { by: byId } : {}), at: isoNow() }
  // Written where the register is, so a mark survives the outbox record it names.
  if (!appendSync(path.join(d, "outcomes.jsonl"), JSON.stringify(ev) + "\n")) {
    err("kibitzer: could not record that"); return 1
  }
  out(`kibitzer: ${hits[0]!.id.slice(0, 6)} marked ${outcome}${byId ? ` (duplicate of ${byId.slice(0, 6)})` : ""}`)
  return 0
}

const findIssue = (cwd: string, prefix: string) => {
  const sid = currentSession(cwd)
  if (!sid) return { error: "kibitzer: no session yet" as const }
  const d = sessDir(cwd, sid)
  const byId = new Map(readIssues(d).map(issue => [issue.id, issue]))
  const hits = [...byId.values()].filter(issue => issue.id.startsWith(prefix))
  if (hits.length !== 1) return { error: hits.length ? `kibitzer: '${prefix}' is ambiguous` : `kibitzer: no issue here starts with '${prefix}'` }
  return { d, issue: hits[0]! }
}

/** Explicit operator feedback only. It is append-only and has no hook path,
 * so it cannot become an acknowledgement gate or delay a host boundary. */
export function cmdIssueState(action: "ack" | "resolve" | "defer" | "reopen", idPrefix?: string, reason?: string, cwd = process.cwd()): number {
  if (!idPrefix) { err(`usage: kibitzer ${action} <id>${action === "defer" ? " [reason]" : ""} [cwd]`); return 2 }
  const hit = findIssue(cwd, idPrefix)
  if ("error" in hit) { err(hit.error); return 1 }
  const state = action === "ack" ? "acknowledged" : action === "resolve" ? "resolved"
    : action === "defer" ? "deferred" : "open"
  const eventReason = reason ?? (action === "reopen" ? "operator reopen" : undefined)
  if (!appendSync(path.join(hit.d!, "issue-events.jsonl"), JSON.stringify({ id: hit.issue!.id, state, at: isoNow(),
    ...(eventReason ? { reason: eventReason } : {}), by: "operator" }) + "\n")) {
    err("kibitzer: could not record that"); return 1
  }
  out(`kibitzer: ${hit.issue!.id.slice(0, 6)} ${state}${eventReason ? ` (${eventReason})` : ""}`)
  return 0
}

function currentIssues(cwd: string) {
  const sid = currentSession(cwd)
  if (!sid) return null
  const d = sessDir(cwd, sid)
  const issues = new Map(readIssues(d).map(issue => [issue.id, issue]))
  return { d, issues: [...issues.values()], states: issueStateMap(d) }
}

export function cmdOpen(cwd = process.cwd()): number {
  const current = currentIssues(cwd)
  if (!current) { err("kibitzer: no session yet"); return 1 }
  const open = current.issues.filter(issue => {
    const state = current.states.get(issue.id)?.state ?? "open"
    return state === "open" || state === "deferred"
  })
  if (!open.length) { out("kibitzer: no open issues"); return 0 }
  for (const issue of open) out(`${issue.id.slice(0, 6)}  ${current.states.get(issue.id)?.state ?? "open"}  ${issue.claim ?? issue.kind ?? "issue"}`)
  return 0
}

export function cmdSummary(cwd = process.cwd()): number {
  const current = currentIssues(cwd)
  if (!current) { err("kibitzer: no session yet"); return 1 }
  const visible = current.issues.filter(issue => {
    const state = current.states.get(issue.id)?.state ?? "open"
    return state === "open" || state === "deferred"
  })
  if (!visible.length) { out("kibitzer: no open or deferred issues"); return 0 }
  for (const issue of visible) {
    const event = current.states.get(issue.id)
    const milestone = issue.timing === "milestone" ? "restore milestone" : issue.timing === "before_next_mutation" ? "before next mutation" : "fresh evidence"
    out(`${issue.id.slice(0, 6)}  ${event?.state ?? "open"}  evidence ${issue.at}  re-surfaces: ${milestone}`)
    out(`  ${issue.claim ?? issue.kind ?? "issue"}`)
  }
  return 0
}

/** Inspect the bounded redacted corpus without invoking an advisor or touching
 * the outbox. `--live` is intentionally diagnostic: it only confirms the
 * current host has a session/context available for an operator comparison. */
export function cmdReplay(fixture?: string, live = false, cwd = process.cwd()): number {
  const defaultFixture = path.resolve(HOME, "..", "..", "tests", "fixtures", "codex-ops-session", "replay.json")
  const source = fixture || defaultFixture
  let corpus: any
  try { corpus = JSON.parse(read(source) ?? "") } catch { err(`kibitzer: unreadable replay corpus ${source}`); return 1 }
  if (!Array.isArray(corpus?.cases)) { err(`kibitzer: replay corpus has no cases: ${source}`); return 1 }
  out(`kibitzer: replay corpus ${source} (${corpus.cases.length} cases; diagnostic only)`)
  for (const item of corpus.cases) out(`  ${item.name}: ${item.expect}`)
  if (live) {
    const sid = currentSession(cwd)
    const transcript = sid ? read(path.join(sessDir(cwd, sid), "transcript"))?.trim() : ""
    out(`live comparison: ${transcript ? "bounded current context available" : "no current transcript"}; no advisory was invoked or injected`)
  }
  return 0
}

/** The measurement the design asks for: is this offering anything beyond
 *  fault-finding, and did any of it change a decision? Volume answers neither,
 *  so it is reported as what it is -- attempts to say something -- next to the
 *  count of distinct issues and what became of them. */
export function cmdStats(cwd = process.cwd()): number {
  const sid = currentSession(cwd)
  if (!sid) { err("kibitzer: no session yet"); return 1 }
  const d = sessDir(cwd, sid)
  const kinds = (read(path.join(d, "kinds")) ?? "").split("\n").filter(Boolean)
  if (kinds.length === 0) { out("kibitzer: nothing said yet"); return 0 }
  const issues = [...new Map(readIssues(d).map(issue => [issue.id, issue])).values()]
  const held = (read(path.join(d, "repeats")) ?? "").split("\n").filter(Boolean).length
  const marks = outcomeMap(d)
  const states = issueStateMap(d)
  const events = readIssueEvents(d)

  out(`advisories published : ${kinds.length}`)
  if (issues.length > 0) out(`distinct issues (semantic) : ${issues.length}`)
  if (held > 0) out(`repeats held back    : ${held}`)
  const counted = new Map<string, number>()
  for (const [, e] of marks) counted.set(e.outcome, (counted.get(e.outcome) ?? 0) + 1)
  if (issues.length > 0) {
    const parts = OUTCOMES.filter(o => counted.get(o)).map(o => `${counted.get(o)} ${o}`)
    parts.push(`${issues.length - marks.size} unmarked`)
    out(`outcomes             : ${parts.join(", ")}`)
    const stateCounts = new Map<string, number>()
    for (const issue of issues) {
      const state = states.get(issue.id)?.state ?? "open"
      stateCounts.set(state, (stateCounts.get(state) ?? 0) + 1)
    }
    out(`issue states         : ${[...stateCounts].map(([s, n]) => `${n} ${s}`).join(", ")}`)
    const resolved = issues.filter(issue => states.get(issue.id)?.state === "resolved")
    const minutes = resolved.map(issue => {
      const at = states.get(issue.id)?.at ?? issue.at
      return Math.max(0, Date.parse(at) - Date.parse(issue.at)) / 60000
    }).filter(Number.isFinite)
    if (minutes.length) out(`delivery to resolution : ${(minutes.reduce((a, b) => a + b, 0) / minutes.length).toFixed(1)}m mean`)
    const reopened = events.filter(event => event.state === "open" &&
      (event.by === "operator" || /fresh evidence|milestone|reopen/.test(event.reason ?? ""))).length
    if (reopened) out(`reopened             : ${reopened}`)
    const phaseOutcomes = new Map<string, number>()
    for (const issue of issues) {
      const outcome = marks.get(issue.id)?.outcome ?? states.get(issue.id)?.state ?? "open"
      const key = `${issue.phase ?? "unknown"}: ${outcome}`
      phaseOutcomes.set(key, (phaseOutcomes.get(key) ?? 0) + 1)
    }
    out(`outcomes by phase    : ${[...phaseOutcomes].map(([p, n]) => `${n} ${p}`).join(", ")}`)
  }
  const suppression = new Map<string, number>()
  for (const line of (read(path.join(d, "suppressions.jsonl")) ?? "").split("\n")) {
    try { const reason = JSON.parse(line).reason; if (reason) suppression.set(reason, (suppression.get(reason) ?? 0) + 1) } catch {}
  }
  if (suppression.size) out(`suppressed           : ${[...suppression].map(([r, n]) => `${n} ${r}`).join(", ")}`)
  out("")
  const counts = new Map<string, number>()
  for (const k of kinds) counts.set(k, (counts.get(k) ?? 0) + 1)
  for (const [k, n] of [...counts].sort((a, b) => b[1] - a[1]))
    out(`  ${String(n).padStart(6)} ${k}`)
  const phases = new Map<string, number>()
  for (const issue of issues) if (issue.phase) phases.set(issue.phase, (phases.get(issue.phase) ?? 0) + 1)
  if (phases.size) out(`phases               : ${[...phases].map(([p, n]) => `${n} ${p}`).join(", ")}`)
  return 0
}

/** Ask for a contribution now. Same no-verdict path as any other cycle. */
export function cmdAdviseNow(cwd = process.cwd()): number {
  if (!isEnabled(cwd)) { err("kibitzer: not enabled here (kibitzer on)"); return 1 }
  const sid = currentSession(cwd)
  if (!sid) { err("kibitzer: no session yet"); return 1 }
  const d = sessDir(cwd, sid)
  if (verifiedWorkerPid(path.join(d, "worker.pid"))) { out("kibitzer: a cycle is already running"); return 0 }
  rm(path.join(d, "last-cycle"))
  // Check synchronously. spawn()'s error event is asynchronous, and this
  // command exits immediately after printing, so an ENOENT listener would never
  // run: the operator would be told to watch a cycle that never started.
  if (!which("setsid")) { err("kibitzer: setsid not found; cannot start a cycle"); return 1 }
  let log: number | undefined
  try {
    log = fs.openSync(path.join(d, "worker.log"), "a")
    const child = spawn("setsid",
      [BIN, "worker", cwd, sid, read(path.join(d, "transcript"))?.trim() || latestTranscript(sid), epochOf(cwd)],
      { detached: true, stdio: ["ignore", log, log] })
    child.on("error", () => { if (log !== undefined) try { fs.closeSync(log) } catch {} })
    child.unref()
  } catch (e) {
    if (log !== undefined) try { fs.closeSync(log) } catch {}
    err(`kibitzer: could not start a cycle (${(e as Error).message})`); return 1
  }
  out("kibitzer: asked for a contribution; watch 'kibitzer tail'")
  return 0
}

/** Old state has no persisted hook transcript. Keep that Claude-only fallback
 * so upgrading does not make an existing manual command lose all context. New
 * sessions from either host use the hook-recorded path above. */
function latestTranscript(sid: string): string {
  const r = spawnSync("find", [path.join(os.homedir(), ".claude", "projects"),
    "-name", `${sid}.jsonl`, "-type", "f"], { encoding: "utf8" })
  return (r.stdout || "").split("\n")[0] ?? ""
}

export function cmdDoctor(): number {
  let bad = 0
  // bun first: it is the shebang's interpreter, so without it on the hook PATH
  // `env` fails before any of our exit-0 handling can run.
  for (const c of ["bun", "flock", "setsid", "timeout", "tail", "find"]) {
    if (which(c)) out(`  ok    ${c}`)
    else { out(`  MISS  ${c}`); bad = 1 }
  }
  const codexDirection = currentHost() === "codex"
  const codexHome = process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex")
  const codexHooks = read(path.join(codexHome, "hooks.json")) ?? ""
  // Bare doctor shows both directions, but an absent optional Codex direction
  // must not turn a working Claude-only installation into an error. An explicit
  // Codex selector or registered Kibitz Codex hook makes its missing tools
  // actionable. OURS_RE is path-agnostic so the documented two-copy install is
  // recognised whichever copy runs doctor.
  let codexRegistered = false
  try {
    const hooks = JSON.parse(codexHooks)?.hooks ?? {}
    codexRegistered = Object.values(hooks).some((groups: any) => Array.isArray(groups)
      && groups.some((group: any) => Array.isArray(group?.hooks)
        && group.hooks.some((hook: any) => typeof hook?.command === "string" && OURS_RE.test(hook.command))))
  } catch {}
  const codexRequired = process.env.KIBITZ_DOCTOR_EXPLICIT === "1"
    || codexRegistered
  for (const c of codexDirection ? ["claude", "bwrap"] : ["codex"]) {
    if (which(c)) out(`  ok    ${c}${codexDirection ? " (Codex direction)" : " (Claude direction)"}`)
    else {
      out(`  MISS  ${c}${codexDirection ? " (Codex direction)" : " (Claude direction)"}`)
      if (!codexDirection || codexRequired) bad = 1
    }
  }
  out(`  ${exists(SCHEMA) ? "ok" : "MISS"}  schema ${SCHEMA}`)
  out(`  ${exists(PROMPT_TMPL) ? "ok" : "MISS"}  prompt ${PROMPT_TMPL}`)
  if (codexDirection && process.platform !== "linux") {
    out("  MISS  Codex direction requires Linux")
    if (codexRequired) bad = 1
  }
  // If a future codex gains confinement flags on `resume`, incremental cycles
  // become possible. Grep the help text; the exit status alone is not a signal.
  if (!codexDirection) {
    const h = spawnSync("codex", ["exec", "resume", "--help"], { encoding: "utf8" })
    if (`${h.stdout ?? ""}${h.stderr ?? ""}`.includes("--sandbox"))
      out("  NOTE  this codex supports resume --sandbox; incremental cycles are possible")
  }
  return bad
}

export const USAGE = `kibitz — cross-host background advisory

  kibitzer on [cwd] [--host H] opt in for this project
  kibitzer off [cwd] [--host H] opt out; reaps in-flight work and pending advice
  kibitzer quiet on|off [--host H] keep analysing and logging, stop injecting
  kibitzer status [cwd] [--host H] what is enabled, pending, running
  kibitzer advise-now [cwd]    ask for a contribution now, without waiting
  kibitzer mute <text>|list|clear   stop hearing about a topic
  kibitzer stats [cwd]         what it has said, and what came of it
  kibitzer open [cwd]          pull-based list of unresolved issues
  kibitzer summary [cwd]       open/deferred issues and their re-surface milestone
  kibitzer ack <id> [cwd]      record optional acknowledgement; never a gate
  kibitzer resolve <id> [cwd]  record an issue as resolved
  kibitzer defer <id> [reason] [cwd]  keep it visible without reinjecting it
  kibitzer reopen <id> [reason] [cwd] explicitly re-open a declined/resolved issue
  kibitzer replay [fixture] [--live]  inspect the deterministic corpus; never inject advice
  kibitzer mark <id> <outcome> record what an advisory led to; the id is the
                               short code in the log. accepted, investigated,
                               declined, or superseded <id it duplicates>.
                               A declined issue stays quiet.
  kibitzer log [cwd] [n]       what has been said so far
  kibitzer tail [cwd]          follow the advisory log
  kibitzer pane [cwd]          open a Herdr side pane following the log
  kibitzer count [cwd]         pending count (for the statusline)
  kibitzer lint <file>         fail if a file contains review/gate language
  kibitzer doctor [--host H]   check dependencies for one direction or both
  kibitzer link [dir]          put a \`kibitzer\` command on your PATH (~/.local/bin)
  kibitzer install [claude-project|claude-user|codex-user] [--force]
                               register hooks (bare install means claude-project)
  kibitzer install claude-channel-user [--force] [--replace-channel]
                               register the named Claude development channel
  kibitzer uninstall [claude-project|claude-user|codex-user|claude-channel-user]
                               remove only kibitzer-owned registrations
  kibitzer statusline [cwd]    pending-count segment for the status line

  kibitzer channel             MCP channel server; pushes advice without waiting
                               for a tool call (opt-in, see README)
  kibitzer hook [--host H] <Event>  hook entrypoint; reads the payload on stdin
  kibitzer worker [--host H] <cwd> <sid> [transcript]  one advisor cycle

  H is claude, codex, or all. Controls default to both hosts when no state-root
  override is set. Session-specific read commands default to Claude; select
  --host codex for a Codex session. With ADVISOR_STATE_ROOT, --host all is
  rejected and Claude is the default for compatibility.`
