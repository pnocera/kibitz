// One Codex cycle. Detached by the hook, so nothing here is on the hot path --
// but everything here is subject to the epoch: `off` during a cycle must make
// the whole cycle inert, including anything it is about to publish.

import { spawnSync } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import * as fs from "node:fs"
import * as path from "node:path"
import {
  ACTIVITY_LINES, BIN, CODEX_TIMEOUT, PROMPT_TMPL, SCHEMA, SENTINEL, TRANSCRIPT_LINES,
  ageMinutes, append, appendSync, epochOf, exists, initSess, isEnabled, isMuted, isoNow,
  listJson, read, rm, validSid, writeWorkerPid,
} from "./core.ts"

/** Read only the end of a file. A transcript grows for the whole session, so
 *  reading it whole and slicing afterwards makes every cycle scale with the
 *  session -- the bounded window would be honoured while the I/O was not. */
function readTailLines(file: string, maxLines: number): string[] {
  const fd = fs.openSync(file, "r")
  try {
    const size = fs.fstatSync(fd).size
    const CHUNK = 1 << 16
    const CAP = 1 << 26                            // 64 MB, for pathological records
    // Collect chunks and join once. Concatenating inside the loop is quadratic
    // in the bytes read, which a transcript with very few, very long lines hits
    // hard -- the line cap alone does not bound the work.
    const chunks: Buffer[] = []
    let pos = size
    let newlines = 0
    let held = 0
    while (pos > 0 && newlines <= maxLines && held < CAP) {
      const len = Math.min(CHUNK, pos)
      pos -= len
      const b = Buffer.alloc(len)
      fs.readSync(fd, b, 0, len, pos)
      chunks.unshift(b)
      held += len
      for (const byte of b) if (byte === 10) newlines++
    }
    return Buffer.concat(chunks).toString("utf8").split("\n").filter(Boolean).slice(-maxLines)
  } finally { try { fs.closeSync(fd) } catch {} }
}

/** Strip our own injected blocks so the advisor never critiques its own advice,
 *  and bound the read at the source: a transcript grows without limit, and
 *  slurping it whole costs the entire session on every cycle. */
function transcriptTail(t: string): { activity: string; goal: string } {
  if (!t || !exists(t)) return { activity: "(transcript unavailable)", goal: "(unknown)" }
  let lines: string[]
  try { lines = readTailLines(t, TRANSCRIPT_LINES) }
  catch { return { activity: "(transcript unreadable)", goal: "(unknown)" } }

  const acts: string[] = []
  let goal = "(unknown)"
  for (const line of lines) {
    let e: any
    try { e = JSON.parse(line) } catch { continue }
    if (e?.isSidechain === true || !e?.message) continue
    const content = e.message.content ?? []
    const parts: string[] = []
    for (const c of Array.isArray(content) ? content : [content]) {
      if (typeof c === "string") parts.push(c)
      else if (c?.type === "text") parts.push(c.text ?? "")
      else if (c?.type === "tool_use")
        parts.push(`→ ${c.name}: ${JSON.stringify(c.input ?? {}).slice(0, 200)}`)
    }
    const text = parts.join("\n")
    if (text === "") continue
    if (e.message.role === "user") {
      const plain = (Array.isArray(content) ? content : [content])
        .map((c: any) => (typeof c === "string" ? c : c?.type === "text" ? c.text ?? "" : ""))
        .join(" ").trim()
      if (plain !== "") goal = plain.slice(0, 800)
    }
    if (text.includes(SENTINEL)) continue          // our own prior advice
    acts.push(`[${e.message.role}] ${text.slice(0, 600)}`)
  }
  return { activity: acts.slice(-40).join("\n\n").split("\n").slice(-ACTIVITY_LINES).join("\n"), goal }
}

/** Digest the whole normalised note. Projecting onto [a-z0-9] collapses any
 *  note written entirely in non-Latin script to the empty string, making every
 *  such advisory a duplicate of the first. */
const fingerprint = (s: string) =>
  createHash("sha1").update(s.toLowerCase().replace(/\s+/g, " ")).digest("hex")

export function cmdWorker(cwd: string, sid: string, transcript = "", admitted = ""): number {
  // `kibitzer worker <cwd> <sid>` is a public entrypoint, and sid becomes a path.
  if (!validSid(sid)) {
    process.stderr.write(`kibitzer: invalid session id\n`)
    return 2
  }
  // One cycle per session. flock(1) rather than an in-process lock: the same
  // guarantee, with semantics the shell test suite can observe directly.
  if (!process.env.KIBITZ_LOCKED) {
    const d0 = initSess(cwd, sid)
    const r = spawnSync("flock", ["-n", path.join(d0, "cycle.lock"),
      BIN, "worker", cwd, sid, transcript, admitted],
      { stdio: "inherit", env: { ...process.env, KIBITZ_LOCKED: "1" } })
    return r.status === 1 ? 0 : (r.status ?? 0)   // lock busy is not an error
  }

  const d = initSess(cwd, sid)
  writeWorkerPid(path.join(d, "worker.pid"))
  const cleanup = () => rm(path.join(d, "worker.pid"))
  process.on("exit", cleanup)

  // The epoch this cycle was authorised in, inherited from the hook that
  // spawned it: a worker that starts running after an off/on pair must not
  // promote pre-opt-out activity into the new epoch.
  const startEpoch = admitted || epochOf(cwd)
  if (!isEnabled(cwd) || epochOf(cwd) !== startEpoch) return 0

  const { activity, goal } = transcriptTail(transcript)
  let diff: string
  const git = spawnSync("git", ["-C", cwd, "rev-parse", "--git-dir"], { stdio: "ignore" })
  if (git.status === 0) {
    const stat = spawnSync("git", ["-C", cwd, "diff", "--stat", "HEAD"], { encoding: "utf8" })
    const full = spawnSync("git", ["-C", cwd, "diff", "HEAD"], { encoding: "utf8", maxBuffer: 1 << 26 })
    diff = `${stat.stdout ?? ""}\n${(full.stdout ?? "").slice(0, 60000)}`
    if (diff.trim() === "") diff = "(no uncommitted changes)"
  } else diff = "(not a git repository — inspect the working tree directly)"

  // Claim the tap's events at-least-once: rename into events-processing, use
  // them, delete on success. A crash leaves them claimed and reclaimable.
  for (const f of listJson(path.join(d, "events-processing")))
    if (ageMinutes(f) > 5)
      try { fs.renameSync(f, path.join(d, "events", path.basename(f))) } catch {}
  for (const f of listJson(path.join(d, "events")))
    try { fs.renameSync(f, path.join(d, "events-processing", path.basename(f))) } catch {}

  const evLines: string[] = []
  for (const f of listJson(path.join(d, "events-processing"))) {
    let e: any
    try { e = JSON.parse(read(f) ?? "") } catch { rm(f); continue }
    if (String(e.epoch ?? 0) !== startEpoch) { rm(f); continue }   // previous epoch
    evLines.push(`${e.at}  ${e.tool}  ${e.input}${e.error ? `\n    ERROR: ${e.error}` : ""}`)
  }
  const events = evLines.slice(-60).join("\n") || "(no tool activity recorded since the last look)"

  const prompt = (read(PROMPT_TMPL) ?? "")
    .split("__CWD__").join(cwd)
    .split("__GOAL__").join(goal)
    .split("__ACTIVITY__").join(activity)
    .split("__EVENTS__").join(events)
    .split("__DIFF__").join(diff)

  const outFile = path.join(d, "tmp", `codex-out.${process.pid}.json`)
  const logPath = path.join(d, "worker.log")
  append(logPath, `--- cycle ${isoNow()} ---\n`)

  // Fresh invocation every cycle. `codex exec resume` accepts neither --sandbox
  // nor --cd, so it cannot hold the confinement boundary; the test suite
  // captures the real invocation and fails if this regresses.
  // Stream both channels straight to the log: a long Codex run should have live
  // diagnostics, and buffering them in memory both hides progress and risks the
  // runtime's synchronous-child output limit on a noisy run.
  const logFd = fs.openSync(logPath, "a")
  let r
  try {
    r = spawnSync("timeout", [String(CODEX_TIMEOUT), "codex", "exec",
      "--sandbox", "read-only",
      "--cd", cwd,
      "--skip-git-repo-check",
      "--output-schema", SCHEMA,
      "-o", outFile,
      "-"], { input: prompt, stdio: ["pipe", logFd, logFd] })
  } finally { try { fs.closeSync(logFd) } catch {} }

  const produced = read(outFile)
  if (r.status !== 0 || !produced || produced.trim() === "") {
    // A failed cycle must never break the session, but it must not be invisible
    // either: record it where `kibitzer status` will show it.
    const tail = (read(logPath) ?? "").split("\n")
      .filter(l => /"message"|^ERROR/.test(l)).slice(-2).join("\n")
    try {
      fs.writeFileSync(path.join(d, "last-error"),
        `${isoNow()}  codex exited ${r.status}${produced ? "" : " (no output)"}\n${tail}\n`)
    } catch {}
    append(logPath, `codex exited ${r.status}\n`)
    return 0
  }
  rm(path.join(d, "last-error"))

  // `off` may have been pressed while Codex was thinking. No lock: the epoch
  // captured before the call decides whether any of this is still wanted.
  if (!isEnabled(cwd) || epochOf(cwd) !== startEpoch) { rm(outFile); return 0 }

  let advisories: any[] = []
  try { advisories = JSON.parse(produced).advisories ?? [] } catch {}
  const seenPath = path.join(d, "seen")
  const seen = new Set((read(seenPath) ?? "").split("\n").filter(Boolean))
  let n = 0

  for (const a of advisories) {
    const note = a?.note ?? ""
    if (!note) continue
    const kind = a?.kind ?? ""
    if (isMuted(cwd, `${kind} ${note}`)) continue
    const fp = fingerprint(note)
    if (seen.has(fp)) continue                     // said it already

    const id = randomUUID()
    const rec = {
      id, epoch: Number(startEpoch), kind, note,
      why_it_matters: a?.why_it_matters ?? "",
      evidence: a?.evidence ?? "",
      confidence: typeof a?.confidence === "number" ? a.confidence : 0,
    }
    // The operator log first, and only then the outbox. We promise the operator
    // a complete log and promise Claude nothing, so an advisory Claude may see
    // and the log may not is the one ordering that breaks the promise. If the
    // log cannot be written, do not publish: an unlogged advisory is worse than
    // an undelivered one, and it blocks nothing either way.
    const t = new Date().toTimeString().slice(0, 8)
    let entry = `\n[${t}] ${kind ? `(${kind})` : ""} ${note}\n`
    if (rec.why_it_matters) entry += `   why: ${rec.why_it_matters}\n`
    if (rec.evidence) entry += `   ref: ${rec.evidence}\n`
    if (!appendSync(path.join(d, "advice.log"), entry)) {
      append(logPath, `could not log ${id}; not publishing it\n`)
      continue
    }
    // Suppress a repeat only once the advisory is actually in the log. Marking
    // it seen first turns a transient logging failure into permanent omission:
    // the advisory is never published, never logged, and deduplicated away for
    // the rest of the session when the log comes back.
    seen.add(fp)
    append(seenPath, fp + "\n")
    append(path.join(d, "kinds"), (kind || "unlabelled") + "\n")

    const tmp = path.join(d, "tmp", `${id}.json`)
    try {
      fs.writeFileSync(tmp, JSON.stringify(rec))
      fs.renameSync(tmp, path.join(d, "outbox", `${Math.floor(Date.now() / 1000)}-${id}.json`))
    } catch { rm(tmp); continue }
    n++
  }
  append(logPath, `published ${n} of ${advisories.length}\n`)
  rm(outFile)
  // Consumed successfully: drop the claim.
  for (const f of listJson(path.join(d, "events-processing"))) rm(f)
  return 0
}
