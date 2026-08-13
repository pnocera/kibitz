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

export type Host = "claude" | "codex"
export type HostScope = Host | "all"

export const validHost = (v: unknown): v is Host => v === "claude" || v === "codex"

/** The entrypoint sets this before it invokes a host-specific command. Claude
 *  remains the default so existing hooks, scripts, and test overrides keep
 *  their state layout without an argument. */
export const currentHost = (): Host => process.env.KIBITZ_HOST === "codex" ? "codex" : "claude"

export function stateRoot(host = currentHost()): string {
  if (process.env.ADVISOR_STATE_ROOT) return process.env.ADVISOR_STATE_ROOT
  if (host === "codex")
    return path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex"), "advisor")
  const legacy = path.join(os.homedir(), ".claude", "advisor")
  const configured = path.join(process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), ".claude"), "advisor")
  if (configured === legacy) return legacy
  // Preserve an enabled historical root when a later CLAUDE_CONFIG_DIR only
  // changes where Claude stores its own configuration.
  if (!exists(path.join(configured, "projects")) && exists(path.join(legacy, "projects"))) return legacy
  return configured
}
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
/** Codex sessions use lifecycle filtering by default. Set ADVISOR_POLICY=legacy
 * only as an explicit rollback while diagnosing a deployment. Claude-host
 * sessions retain their established policy. */
export const ISSUE_LIFECYCLE_V1 = currentHost() === "codex" && process.env.ADVISOR_POLICY !== "legacy"
export const LEASE_SECONDS = num(process.env.ADVISOR_LEASE_SECONDS, 120)
export const CODEX_TIMEOUT = num(process.env.ADVISOR_CODEX_TIMEOUT, 300)
export const CLAUDE_TIMEOUT = num(process.env.ADVISOR_CLAUDE_TIMEOUT, 300)
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

const markerPath = (host = currentHost()) => path.join(stateRoot(host), "host")

/** Refuse a host collision before it can turn two independent sessions into one
 *  queue. An existing unmarked state root is the historical Claude root. */
export function ensureHostRoot(host = currentHost()): boolean {
  const root = stateRoot(host)
  const marker = read(markerPath(host))?.trim()
  if (marker) return marker === host
  let entries: string[] = []
  try { entries = fs.readdirSync(root) } catch {}
  if (host === "codex" && entries.length > 0) return false
  try { fs.mkdirSync(root, { recursive: true }); fs.writeFileSync(markerPath(host), host + "\n") }
  catch { return false }
  return true
}

export const projDir = (cwd: string, host = currentHost()) => path.join(stateRoot(host), "projects", hashPath(cwd))
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

/** fsync a directory, so a name created in it survives a power loss. */
function fsyncDir(p: string): boolean {
  let fd: number | undefined
  try { fd = fs.openSync(p, "r"); fs.fsyncSync(fd); return true }
  catch { return false }
  finally { if (fd !== undefined) try { fs.closeSync(fd) } catch {} }
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
 *  The human-readable ledger is still appended, because it is what an operator
 *  reads and what deliveredCount() folds in for sessions that predate markers. */
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
  // The ledger is what an operator reads; the marker above is the claim. Either
  // record, once durable, suppresses a redelivery -- so one failing is survivable.
  // Written before any directory is synced, because a sync taken earlier cannot
  // persist a name created after it.
  const ledgerWritten = appendSync(path.join(sessionDir, "ledger"), `${id}\n`)

  // Now persist the names, not only the contents: an unsynced directory entry
  // can vanish across a power loss, and the marker IS the claim. Both records
  // live under sessionDir -- the ledger directly, the marker one level down in a
  // directory mkdirp may have just created -- so syncing sessionDir is what
  // makes either of them nameable after a crash, and neither counts without it.
  const parentSynced = fsyncDir(sessionDir)
  const markerSynced = fsyncDir(dir) && parentSynced
  const ledgered = ledgerWritten && parentSynced
  if (!ledgered)
    process.stderr.write(`kibitzer: claimed ${id} but could not record it durably in the ledger\n`)
  // Both failing is not. The marker may exist only in page cache, so a power
  // loss here leaves no durable record that this advisory was ever claimed, and
  // the next consumer would deliver it again. Refusing the claim loses it
  // instead, which is the direction this contract fails in by design.
  if (!markerSynced && !ledgered) {
    // Remove the marker too. We are dropping this advisory, so counting it as
    // committed would make `status` overstate exactly when storage is failing.
    // If the unlink itself does not persist, the marker returns and suppresses
    // a redelivery -- still loss, which is the direction we fail in.
    rm(path.join(dir, markerName(id)))
    process.stderr.write(`kibitzer: no durable record for ${id}; dropping it rather than ` +
      "risking a duplicate\n")
    return false
  }
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

/** How many advisories this session has delivered: the union of both records.
 *
 *  Markers and ledger lines are not alternatives. A session upgraded from the
 *  ledger-only version accumulates markers for new deliveries while its earlier
 *  ones exist only as ledger lines, so preferring either record alone
 *  under-reports the other -- and picking the ledger only when there are no
 *  markers makes the first new delivery *reduce* the reported total.
 *
 *  A ledger line whose marker exists is the same delivery counted twice, so the
 *  ledger only contributes ids that no marker covers. */
export function deliveredCount(sessionDir: string): number {
  let markers: string[] = []
  try { markers = fs.readdirSync(path.join(sessionDir, "delivered")) } catch {}
  const have = new Set(markers)
  const legacy = new Set<string>()
  for (const id of (read(path.join(sessionDir, "ledger")) ?? "").split("\n"))
    if (id !== "" && !have.has(markerName(id))) legacy.add(id)
  return have.size + legacy.size
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
export function writeState(cwd: string, enabled: boolean): boolean {
  if (!ensureHostRoot()) return false
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
    return true
  } catch { return false } finally { rm(tmp) }
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

// --- issue identity ---------------------------------------------------------
//
// Two advisories are the same issue when they make the same claim about the
// same code, however the sentence is arranged. Hashing the note alone made
// identity literal: a rephrased restatement was a new advisory, and one concern
// arrived twenty-five times in a single session under fourteen different kinds.
// So identity is the distinctive words of the claim plus the files it cites,
// and an advisory is a repeat only while those files still say what they said.

const STOP = new Set(`about after all already also and any are around because
been before being both but can cannot come could current currently does doing
done down each either else even every for from had has have here how however
into its itself just like made make many may might more most much must need
needs never new now off once one only onto other over own past per rather
same see should since some still such take than that the their them then there
these they thing things this those through thus too under until upon use used
using very was way well were what when where whether which while who why will
with within without would you your
advisory advisories kibitz kibitzer note ref why matters currently instead`
  .split(/\s+/).filter(Boolean))

/** The distinctive words of a claim: identifiers, paths and content words.
 *  Bare numbers are dropped -- a line number moves with every edit above it and
 *  was never part of what the advisory was saying. */
export function claimTokens(text: string): Set<string> {
  const out = new Set<string>()
  for (const raw of String(text).toLowerCase().split(/[^a-z0-9_./-]+/)) {
    const t = raw.replace(/^[-.]+/, "").replace(/[-.]+$/, "")
    if (t.length < 3 || STOP.has(t) || /^[\d.-]+$/.test(t)) continue
    out.add(t)
  }
  return out
}

/** |a ∩ b| / min(|a|,|b|). Containment rather than Jaccard: a restatement that
 *  bolts on a paragraph of fresh prose is still the same claim, and Jaccard
 *  would score it as new for being longer. */
export function containment(a: Set<string>, b: Set<string>): number {
  const [small, big] = a.size <= b.size ? [a, b] : [b, a]
  // An empty set matches nothing. Load-bearing: a note in a script the tokeniser
  // cannot segment yields no tokens, and scoring that as a perfect match would
  // collapse every such advisory into the first one.
  if (small.size === 0) return 0
  let hits = 0
  for (const t of small) if (big.has(t)) hits++
  return hits / small.size
}

/** The files an advisory cites, from its evidence field. Line and range
 *  suffixes are stripped: they drift with every edit above them, while the file
 *  is what the claim is actually about. Only paths that exist are kept, which
 *  also drops a citation that was imagined. */
export function citedPaths(evidence: string, cwd: string): string[] {
  // Resolved once, and everything is decided against it. This text is written by
  // a model: `x/../../../../../etc/passwd` never starts with `..` and so clears
  // a naive prefix check, while naming a file that pathsSignature would go on to
  // read. A citation must not become ambient filesystem access.
  let root: string
  try { root = fs.realpathSync(cwd) } catch { return [] }
  const found = new Set<string>()
  for (const word of String(evidence).split(/[\s,;()[\]]+/)) {
    const t = word.replace(/[.,;:]+$/, "").replace(/:[\d,\s-]*$/, "")
    // A slash or a dot, or a capital: Makefile, Dockerfile and LICENSE are cited
    // as often as any .ts file, and requiring an extension drops them into the
    // evidence-free rule where they are much harder to match. Lowercase prose
    // still cannot qualify, so a sentence cannot accidentally name a file.
    if (!t || t.startsWith("-") || !(/[/.]/.test(t) || /[A-Z]/.test(t))) continue
    try {
      // realpath, not resolve: a symlink inside the workspace pointing out of it
      // would otherwise pass a textual containment check and be read anyway.
      const abs = fs.realpathSync(path.resolve(root, t))
      if (abs !== root && !abs.startsWith(root + path.sep)) continue
      if (!fs.statSync(abs).isFile()) continue
      found.add(path.relative(root, abs))
    } catch {}
  }
  return [...found].sort()
}

/** What the cited files hold now. An advisory about code that has since changed
 *  is not a repeat -- that is new evidence, and it gets through. */
export function pathsSignature(cwd: string, paths: string[]): string {
  const h = createHash("sha1")
  for (const rel of paths)
    h.update(rel).update("\0").update(read(path.join(cwd, rel)) ?? "").update("\0")
  return h.digest("hex")
}

/** How alike two claims must be to count as one. Env-tunable because the right
 *  number is a judgement about an advisor's writing, not a fact about code. */
export const REPEAT_SIMILARITY = (() => {
  const n = Number(process.env.ADVISOR_REPEAT_SIMILARITY)
  return Number.isFinite(n) && n > 0 && n <= 1 ? n : 0.6
})()

export interface Issue {
  id: string; at: string; kind: string; fp: string
  tokens: string[]; paths: string[]; sig: string
  /** New records carry a stable identity; old delivery-shaped records remain
   * readable and are mapped to their historical id below. */
  key?: string; claim?: string; scope?: string; timing?: AdviceTiming
  evidence_freshness?: EvidenceFreshness; phase?: OperationPhase
}

export type AdviceTiming = "now" | "before_next_mutation" | "milestone" | "deferred"
export type EvidenceFreshness = "current_activity" | "current_state" | "historical_context"
export type IssueState = "open" | "acknowledged" | "resolved" | "declined" | "deferred"
export type OperationPhase = "inspect" | "diagnose" | "mutate" | "wait_monitor" | "verify" | "restore" | "unknown"

export const validTiming = (v: unknown): v is AdviceTiming =>
  v === "now" || v === "before_next_mutation" || v === "milestone" || v === "deferred"
export const validFreshness = (v: unknown): v is EvidenceFreshness =>
  v === "current_activity" || v === "current_state" || v === "historical_context"

/** A semantic identity is intentionally based on the model's stable claim and
 * operation scope, never its presentational note. Path/unit tokens make two
 * same-word concerns about different targets distinct. */
export function issueKey(claim: string, scope: string, identifiers: string[]): string {
  const normal = claim.toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ")
  const ids = identifiers.map(x => x.toLocaleLowerCase().trim()).filter(Boolean).sort().join("\u0000")
  return createHash("sha256").update(`${normal}\u0000${scope}\u0000${ids}`).digest("hex")
}

export interface Candidate { tokens: Set<string>; paths: string[] }

/** Append-only, one JSON object per line, unreadable lines skipped. Both files
 *  outlive the outbox record, which is deleted on delivery -- an advisory has to
 *  stay addressable after it has been read, or no outcome can name it. */
function readJsonl<T>(p: string): T[] {
  const out: T[] = []
  for (const line of (read(p) ?? "").split("\n")) {
    if (line.trim() === "") continue
    try { out.push(JSON.parse(line) as T) } catch {}
  }
  return out
}

export const readIssues = (sessionDir: string): Issue[] =>
  readJsonl<Issue>(path.join(sessionDir, "issues.jsonl"))

export interface OutcomeEvent { id: string; outcome: string; by?: string; at: string }

export const readOutcomes = (sessionDir: string): OutcomeEvent[] =>
  readJsonl<OutcomeEvent>(path.join(sessionDir, "outcomes.jsonl"))

/** Latest event per issue wins: the file is a history, and an operator is
 *  allowed to change their mind without the record being rewritten. */
export function outcomeMap(sessionDir: string): Map<string, OutcomeEvent> {
  const m = new Map<string, OutcomeEvent>()
  for (const e of readOutcomes(sessionDir)) if (e?.id) m.set(e.id, e)
  return m
}

export interface IssueEvent { id: string; state: IssueState; at: string; reason?: string; by?: string }
export const readIssueEvents = (sessionDir: string): IssueEvent[] =>
  readJsonl<IssueEvent>(path.join(sessionDir, "issue-events.jsonl"))

/** State is append-only and survives an outbox deletion. Old `mark` records
 * retain their original meaning through this deterministic compatibility map. */
export function issueStateMap(sessionDir: string): Map<string, IssueEvent> {
  const states = new Map<string, IssueEvent>()
  for (const issue of readIssues(sessionDir)) states.set(issue.id, { id: issue.id, state: "open", at: issue.at })
  for (const event of readIssueEvents(sessionDir)) if (event?.id && event?.state) states.set(event.id, event)
  for (const event of readOutcomes(sessionDir)) {
    if (!event?.id || states.has(event.id) && readIssueEvents(sessionDir).some(x => x.id === event.id)) continue
    const state: IssueState = event.outcome === "declined" ? "declined"
      : event.outcome === "superseded" ? "resolved"
      : event.outcome === "accepted" || event.outcome === "investigated" ? "acknowledged" : "open"
    states.set(event.id, { id: event.id, state, at: event.at, reason: `legacy mark: ${event.outcome}` })
  }
  return states
}

/** The issue a candidate repeats, or null if it is saying something new.
 *
 *  Shared by both directions -- Codex advising Claude and Claude advising Codex
 *  publish through the same loop, so this is the only place the question is
 *  asked. Three rules, and the middle one is the whole point: citing the same
 *  file is not enough (one file holds many separate problems) and similar
 *  wording is not enough (two files can be described alike), so a repeat has to
 *  be both, over code that has not moved. */
export function repeatedIssue(
  cand: Candidate, issues: Issue[], cwd: string,
  outcomeOf: (id: string) => string | undefined = () => undefined,
): Issue | null {
  for (const issue of issues) {
    // No shortcut for identical wording: the freshness rule below governs every
    // case, or the documented policy is not the policy. A repeat of the same
    // normalised sentence never reaches here -- `seen` catches it beforehand.
    // Containment divides by the smaller set, so a terse advisory whose handful
    // of words all appear inside a long one scores 1.0 against it. Below this
    // many distinctive words there is not enough of a claim to be sure it is the
    // same claim, and a false suppression is silent. Ahead of both branches: the
    // uncited branch has a higher bar but the same arithmetic, so a three-word
    // note would clear 0.8 against any longer note that happens to contain it.
    if (Math.min(cand.tokens.size, issue.tokens.length) < 8) continue
    const sim = containment(cand.tokens, new Set(issue.tokens))
    const shared = issue.paths.filter(p => cand.paths.includes(p))
    if (shared.length === 0) {
      // Nothing to check the claim against. Only near-identical prose counts,
      // because a wrong guess here suppresses an advisory about other code.
      if (cand.paths.length === 0 && issue.paths.length === 0 && sim >= 0.8) return issue
      continue
    }
    if (sim < REPEAT_SIMILARITY) continue
    // Declined once is declined: re-raising it on the next unrelated edit to the
    // same file is the re-litigation this exists to stop. Anything else gets
    // through the moment its evidence changes.
    if (outcomeOf(issue.id) === "declined") return issue
    if (issue.sig === pathsSignature(cwd, issue.paths)) return issue
  }
  return null
}

/** Substring, case-insensitive, against "<kind> <note> <evidence>". Evidence is
 *  included so `kibitzer mute src/install.ts` mutes a file, not just a phrase. */
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
  if (!ensureHostRoot()) throw new Error(`state root belongs to another host: ${stateRoot()}`)
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
  /^("\$\{CLAUDE_PLUGIN_ROOT\}"\/bin\/kibitzer|"\/[^"]*\/bin\/kibitzer"|\/[^ "]*\/bin\/kibitzer) hook (?:--host codex )?[A-Za-z]+$/

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
