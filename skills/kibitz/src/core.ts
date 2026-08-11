// Shared state, paths and predicates. Kept byte-compatible with the shell
// implementation this replaces: same directory layout, same file formats, same
// `state` line, same ledger. An upgrade must not orphan a live installation.

import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"

export const HOME = (() => {
  if (process.env.ADVISOR_HOME) return process.env.ADVISOR_HOME
  // Resolve symlinks first: invoked through a repo-root bin/ or an installer's
  // link, the link's directory is not where lib/ and install/ live.
  const self = fs.realpathSync(process.argv[1] ?? "")
  return path.resolve(path.dirname(self), "..")
})()

export const STATE_ROOT =
  process.env.ADVISOR_STATE_ROOT ?? path.join(os.homedir(), ".claude", "advisor")
export const SCHEMA = path.join(HOME, "lib", "advice.schema.json")
export const PROMPT_TMPL = path.join(HOME, "lib", "prompt.tmpl")
export const BIN = path.join(HOME, "bin", "kibitzer")

// Injected blocks carry this sentinel so the worker can strip its own prior
// output from the transcript tail, and never critique its own advice.
export const SENTINEL = "⟦kibitz⟧"

const num = (v: string | undefined, d: number) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : d
}
export const MAX_PER_DRAIN = num(process.env.ADVISOR_MAX_PER_DRAIN, 3)
export const LEASE_SECONDS = num(process.env.ADVISOR_LEASE_SECONDS, 120)
export const CODEX_TIMEOUT = num(process.env.ADVISOR_CODEX_TIMEOUT, 300)
export const MIN_INTERVAL = num(process.env.ADVISOR_MIN_INTERVAL, 45)
export const TRANSCRIPT_LINES = num(process.env.ADVISOR_TRANSCRIPT_LINES, 400)
export const ACTIVITY_LINES = num(process.env.ADVISOR_ACTIVITY_LINES, 120)

// ---------------------------------------------------------------- paths ----

// POSIX cksum (CRC-32/CKSUM), reproduced exactly: the state directory for a
// project is keyed by it, so a different hash silently orphans existing state.
const CRC = new Uint32Array(256)
for (let i = 0; i < 256; i++) {
  let c = i << 24
  for (let k = 0; k < 8; k++) c = c & 0x80000000 ? (c << 1) ^ 0x04c11db7 : c << 1
  CRC[i] = c >>> 0
}
export function hashPath(s: string): string {
  const b = Buffer.from(s, "utf8")
  let c = 0
  for (const x of b) c = ((c << 8) ^ CRC[((c >>> 24) ^ x) & 0xff]!) >>> 0
  for (let n = b.length; n > 0; n >>>= 8)
    c = ((c << 8) ^ CRC[((c >>> 24) ^ (n & 0xff)) & 0xff]!) >>> 0
  return `${(~c) >>> 0}${b.length}`.slice(0, 12)
}

/** A session id becomes a path segment, so every source of one is checked:
 *  hook payloads (the normal producer), the channel's environment override, and
 *  Claude's session registry. Separators or traversal would let a caller read
 *  and write outside the sessions root. */
export const validSid = (v: unknown): v is string =>
  typeof v === "string" && /^[A-Za-z0-9._-]+$/.test(v) && v !== "." && v !== ".."

export const projDir = (cwd: string) => path.join(STATE_ROOT, "projects", hashPath(cwd))
export const sessDir = (cwd: string, sid: string) => path.join(projDir(cwd), "sessions", sid)

// ------------------------------------------------------------ small fs ----

export const read = (p: string): string | null => {
  try { return fs.readFileSync(p, "utf8") } catch { return null }
}
export const exists = (p: string) => fs.existsSync(p)
export const mkdirp = (p: string) => { try { fs.mkdirSync(p, { recursive: true }) } catch {} }
export const rm = (p: string) => { try { fs.unlinkSync(p) } catch {} }
export const append = (p: string, s: string) => { try { fs.appendFileSync(p, s) } catch {} }

/** Write then rename: readers never observe a partial file. */
export function writeAtomic(target: string, data: string) {
  const tmp = `${target}.w.${process.pid}`
  try {
    fs.writeFileSync(tmp, data)
    fs.renameSync(tmp, target)
  } catch { rm(tmp) }
}

/** Durable append. The delivery ledger must survive a host crash, or the
 *  documented failure mode (lose an advisory, never duplicate one) is a fiction. */
export function appendSync(p: string, line: string): boolean {
  let fd: number | undefined
  try {
    fd = fs.openSync(p, "a")
    // Loop on the byte count: a short write followed by a successful fsync
    // would durably store a truncated id, and the ledger check that prevents a
    // second delivery is an exact line match.
    const buf = Buffer.from(line, "utf8")
    let off = 0
    while (off < buf.length) {
      const n = fs.writeSync(fd, buf, off, buf.length - off)
      if (!(n > 0)) return false
      off += n
    }
    fs.fsyncSync(fd)
    return true
  } catch {
    // Report it. Swallowing this breaks the whole delivery contract: the caller
    // would emit an advisory that no durable ledger records, and a later
    // consumer would deliver it again -- duplicating instead of losing.
    return false
  } finally { if (fd !== undefined) try { fs.closeSync(fd) } catch {} }
}

/** Claim the right to deliver one advisory, atomically and across processes.
 *
 *  Reading the ledger and then appending to it is not atomic, and the lease
 *  makes that gap reachable: a consumer paused after claiming a record loses it
 *  to a reclaim after LEASE_SECONDS, the second consumer delivers, and the first
 *  then resumes with a stale in-memory view and delivers the same advisory
 *  again. O_EXCL creation of a per-id marker is the commit point instead --
 *  exactly one caller can create it, whatever the timing.
 *
 *  The human-readable ledger is still appended, because it is what `status`
 *  counts and what an operator reads. */
export function claimDelivery(sessionDir: string, id: string): boolean {
  // The id is now a filename, which it never was while the ledger was only text.
  // A corrupt or planted record naming "../../x" would otherwise write outside
  // the marker directory, so it is hashed rather than trusted.
  const dir = path.join(sessionDir, "delivered")
  mkdirp(dir)
  let fd: number | undefined
  try {
    fd = fs.openSync(path.join(dir, markerName(id)), "wx")   // wx: fails if it exists
    fs.fsyncSync(fd)
  } catch {
    return false                                  // someone else owns delivery
  } finally { if (fd !== undefined) try { fs.closeSync(fd) } catch {} }
  // Persist the name itself, not just the file's contents: an unsynced
  // directory entry can vanish across a power loss, and the marker IS the claim.
  let dfd: number | undefined
  try { dfd = fs.openSync(dir, "r"); fs.fsyncSync(dfd) } catch {} finally {
    if (dfd !== undefined) try { fs.closeSync(dfd) } catch {}
  }
  // The ledger is what `status` counts and an operator reads. If it cannot be
  // written the claim still stands -- undoing it would risk a duplicate, which
  // is worse -- but say so rather than report a silent success.
  if (!appendSync(path.join(sessionDir, "ledger"), `${id}\n`))
    process.stderr.write(`kibitzer: delivered ${id} but could not append the ledger\n`)
  return true
}

const markerName = (id: string) =>
  createHash("sha1").update(id).digest("hex")

export function alreadyDelivered(sessionDir: string, id: string): boolean {
  if (exists(path.join(sessionDir, "delivered", markerName(id)))) return true
  // Upgrade path: an installation delivered by the previous version has ledger
  // lines and no markers. Without this a queued record it had already delivered
  // would go out a second time on the first drain after updating.
  const led = read(path.join(sessionDir, "ledger"))
  return led !== null && led.split("\n").includes(id)
}

export const listJson = (dir: string): string[] => {
  try {
    return fs.readdirSync(dir).filter(f => f.endsWith(".json")).sort()
      .map(f => path.join(dir, f))
  } catch { return [] }
}

export const ageMinutes = (p: string): number => {
  try { return (Date.now() - fs.statSync(p).mtimeMs) / 60000 } catch { return 0 }
}

// -------------------------------------------------------------- process ----

/** /proc/<pid>/stat field 22. A bare pid is not an identity: the kernel reuses
 *  numbers, and signalling a reused one kills an unrelated process. */
export function procStart(pid: number): string | null {
  const s = read(`/proc/${pid}/stat`)
  if (!s) return null
  // The comm field can contain spaces and parentheses, so split after the last ')'.
  const rest = s.slice(s.lastIndexOf(")") + 2).split(" ")
  return rest[19] ?? null           // field 22 overall, 20th after comm+state
}

export function writeWorkerPid(p: string) {
  try { fs.writeFileSync(p, `${process.pid} ${procStart(process.pid) ?? ""}\n`) } catch {}
}

/** The pid, but only when the pidfile still refers to *our* live worker. */
export function verifiedWorkerPid(p: string): number | null {
  const raw = read(p)
  if (!raw) return null
  const [pidS, stamp] = raw.trim().split(/\s+/)
  const pid = Number(pidS)
  if (!Number.isInteger(pid) || pid <= 0) return null
  try { process.kill(pid, 0) } catch { return null }
  const now = procStart(pid)
  if (!now || !stamp || now !== stamp) return null      // pid was reused
  const cmd = read(`/proc/${pid}/cmdline`) ?? ""
  if (!/kibitz(er)?/.test(cmd)) return null
  return pid
}

/** Terminate a worker and everything it started.
 *
 *  `pkill -P` is one level deep, and the chain is worker -> timeout -> codex,
 *  so it can leave Codex running for the rest of its timeout. Workers are
 *  spawned under setsid, which makes each one a process-group leader, so
 *  signalling the negative pid reaches the whole tree in one call.
 *
 *  Only when it really is the leader: a worker started directly from a shell
 *  shares that shell's group, and signalling that group would kill the caller. */
export function killTree(pid: number) {
  // Compare against OUR group, not against the pid. setsid makes the outer
  // process the leader and the worker that records its pid is the inner one
  // flock launched, so pgid never equals pid and a `pgid === pid` test would
  // make this branch unreachable. A different group means the worker was
  // detached and the whole group is ours to end; the same group means it was
  // started from the caller's shell, where signalling the group kills the
  // caller.
  const pgid = pgidOf(pid)
  if (Number.isInteger(pgid) && pgid > 0 && pgid !== pgidOf(process.pid)) {
    try { process.kill(-pgid, "SIGTERM"); return } catch {}
  }
  // Not a group leader (a worker started straight from a shell): walk the tree
  // instead. `pkill -P` is one level, and the chain is worker -> timeout ->
  // codex, so one level can leave Codex behind.
  for (const kid of descendants(pid)) try { process.kill(kid, "SIGTERM") } catch {}
  try { process.kill(pid, "SIGTERM") } catch {}
}

function pgidOf(pid: number): number {
  const stat = read(`/proc/${pid}/stat`)
  if (!stat) return NaN
  return Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[2])
}

/** Every descendant pid, deepest first, via /proc. */
function descendants(pid: number): number[] {
  const out: number[] = []
  const visit = (p: number, depth: number) => {
    if (depth > 8) return
    const r = spawnSync("pgrep", ["-P", String(p)], { encoding: "utf8" })
    for (const l of (r.stdout ?? "").split("\n")) {
      const k = Number(l.trim())
      if (Number.isInteger(k) && k > 0) { visit(k, depth + 1); out.push(k) }
    }
  }
  visit(pid, 0)
  return out
}

// ---------------------------------------------------------------- state ----
//
// The opt-out boundary is a value, not a timing window.
//
// Locks were tried first and were the wrong tool: producers, the worker and the
// drain are separate processes, and an exclusive lock across them serialised
// producers, dropped events, leaked a descriptor into a detached child, and
// wedged delivery for as long as any holder lived. An epoch has none of those
// failure modes -- `off` bumps it, records carry the epoch they were born in,
// and consumers ignore older ones, so a late writer is already inert.
//
// `enabled` and the epoch live in ONE file read in a single operation. As two
// files they could not be sampled together: a hook that passed the enabled
// check could read an epoch from the other side of an off/on pair.
//
// Format: "<0|1> <epoch>".

export interface State { enabled: boolean; epoch: string }

export function readState(cwd: string): State {
  const p = projDir(cwd)
  const parse = (s: string): State => {
    const [e, ep] = s.trim().split(/\s+/)
    return { enabled: e === "1", epoch: ep ?? "0" }
  }
  const cur = read(path.join(p, "state"))
  if (cur !== null) return parse(cur)

  // Migration from the two-file scheme: an install enabled under the old layout
  // has `enabled` and no `state`, and without this reads as disabled and
  // silently stops watching after an upgrade.
  if (exists(path.join(p, "enabled"))) {
    const tmp = path.join(p, `state.mig.${process.pid}`)
    try {
      fs.writeFileSync(tmp, "1 0\n")
      // No-clobber: a concurrent `off` may already have written real state, and
      // migration must never overwrite it. Report what is actually on disk.
      try { fs.linkSync(tmp, path.join(p, "state")) } catch {}
      if (exists(path.join(p, "state"))) rm(path.join(p, "enabled"))
    } catch {} finally { rm(tmp) }
    const after = read(path.join(p, "state"))
    return after !== null ? parse(after) : { enabled: true, epoch: "0" }
  }
  return { enabled: false, epoch: "0" }
}

/** Always advances the epoch: every transition invalidates queued work. */
export function writeState(cwd: string, enabled: boolean) {
  const p = projDir(cwd)
  mkdirp(p)
  const cur = readStateRaw(p)
  const next = Number(cur.epoch) + 1
  // Private temp name: a shared one lets two concurrent control commands
  // overwrite each other's prepared state between write and rename.
  const tmp = path.join(p, `state.w.${process.pid}`)
  try {
    fs.writeFileSync(tmp, `${enabled ? 1 : 0} ${next}\n`)
    fs.renameSync(tmp, path.join(p, "state"))
  } catch {} finally { rm(tmp) }
}

function readStateRaw(p: string): State {
  const s = read(path.join(p, "state"))
  if (s === null) return { enabled: false, epoch: "0" }
  const [e, ep] = s.trim().split(/\s+/)
  return { enabled: e === "1", epoch: ep ?? "0" }
}

export const epochOf = (cwd: string) => readState(cwd).epoch
export const isEnabled = (cwd: string) => readState(cwd).enabled
export const isQuiet = (cwd: string) => exists(path.join(projDir(cwd), "quiet"))

// Tools that only look at things: nothing to remark on, so they never trigger a
// cycle, though the worker still sees them through the transcript.
const NAVIGATION = new Set([
  "Read", "Glob", "Grep", "TodoWrite", "NotebookRead",
  "WebFetch", "WebSearch", "ListMcpResources", "Task",
])
export const isNavigation = (tool: string) => NAVIGATION.has(tool)

/** Substring, case-insensitive, against "<kind> <note>". */
export function isMuted(cwd: string, text: string): boolean {
  const m = read(path.join(projDir(cwd), "mutes"))
  if (!m) return false
  const hay = text.toLowerCase()
  return m.split("\n").some(line => line.trim() !== "" && hay.includes(line.toLowerCase()))
}

export function initSess(cwd: string, sid: string): string {
  // Guard at the sink, not only at each ingress: this is where a session id
  // first becomes directories on disk, so every present and future caller is
  // covered by one check.
  if (!validSid(sid)) throw new Error(`invalid session id: ${JSON.stringify(sid)}`)
  const d = sessDir(cwd, sid)
  for (const sub of ["tmp", "outbox", "outbox-processing", "events", "events-processing"])
    mkdirp(path.join(d, sub))
  for (const f of ["advice.log", "ledger"]) if (!exists(path.join(d, f))) append(path.join(d, f), "")
  try { fs.writeFileSync(path.join(projDir(cwd), "current-session"), `${sid}\n`) } catch {}
  return d
}

export const currentSession = (cwd: string): string | null => {
  // Validated on read as well as on write: the file is persisted state, and a
  // consumer that trusts it turns one bad write into a lasting path escape.
  const v = read(path.join(projDir(cwd), "current-session"))?.trim()
  return validSid(v) ? v : null
}

// What counts as ours, stated exactly, because install and uninstall DELETE
// whatever matches. We write two shapes and no others: the plugin form, and the
// installer's absolute path, quoted so a directory with spaces still runs.
//
//   claimed    "${CLAUDE_PLUGIN_ROOT}"/bin/kibitzer hook Stop
//   claimed    /home/u/kibitz/bin/kibitzer hook Stop
//   claimed    "/dir with space/kibitz/bin/kibitzer" hook Stop
//   survives   logger /x/bin/kibitzer hook Stop
//   survives   env X=1 /x/bin/kibitzer hook Stop
//
// Path-agnostic on purpose, so an upgrade replaces the old command instead of
// registering a second one. The unquoted branch forbids spaces deliberately:
// allowing them would swallow `/usr/bin/logger /x/bin/kibitzer hook Stop`, and
// deleting a command a user wrote is worse than anything it would buy.
export const OURS_RE =
  /^("\$\{CLAUDE_PLUGIN_ROOT\}"\/bin\/kibitzer|"\/[^"]*\/bin\/kibitzer"|\/[^ "]*\/bin\/kibitzer) hook [A-Za-z]+$/

export const isoNow = () => {
  const d = new Date()
  const off = -d.getTimezoneOffset()
  const s = off < 0 ? "-" : "+"
  const p2 = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0")
  return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate()) +
    "T" + p2(d.getHours()) + ":" + p2(d.getMinutes()) + ":" + p2(d.getSeconds()) +
    s + p2(off / 60) + ":" + p2(off % 60)
}

export const which = (cmd: string): boolean => {
  const r = spawnSync("command", ["-v", cmd], { shell: true, stdio: "ignore" })
  return r.status === 0
}
