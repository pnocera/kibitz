// One Codex cycle. Detached by the hook, so nothing here is on the hot path --
// but everything here is subject to the epoch: `off` during a cycle must make
// the whole cycle inert, including anything it is about to publish.

import { spawnSync } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import * as fs from "node:fs"
import * as path from "node:path"
import {
  BIN, PROMPT_TMPL,
  ageMinutes, append, appendSync, epochOf, initSess, isEnabled, isMuted, isoNow,
  currentHost, listJson, read, rm, validSid, writeWorkerPid,
} from "./core.ts"
import { adapterFor } from "./hosts.ts"
import { invokeRunner, reserveCycle } from "./runners.ts"

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

  const adapter = adapterFor(currentHost())
  const { activity, goal } = adapter.readContext(transcript)
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
    .split("__HOST_AGENT__").join(currentHost() === "codex" ? "Codex" : "Claude Code")
    .split("__SOURCE_BOUNDARY__").join(adapter.advisor === "claude"
      ? "You can use only the material below. Do not claim independent repository verification."
      : "Read the repository yourself. The summary above is a pointer, not a source — verify anything you intend to rely on.")

  const outFile = path.join(d, "tmp", `${adapter.advisor}-out.${process.pid}.json`)
  const logPath = path.join(d, "worker.log")
  append(logPath, `--- ${adapter.advisor} cycle ${isoNow()} ---\n`)
  if (!reserveCycle(d, currentHost())) {
    try { fs.writeFileSync(path.join(d, "last-error"), `${isoNow()}  advisor budget exhausted\n`) } catch {}
    append(logPath, "advisor budget exhausted\n")
    return 0
  }
  const run = invokeRunner(currentHost(), cwd, prompt, outFile, logPath)
  if (!run.ok) {
    // A failed cycle must never break the session, but it must not be invisible
    // either: record it where `kibitzer status` will show it.
    const tail = (read(logPath) ?? "").split("\n")
      .filter(l => /"message"|^ERROR/.test(l)).slice(-2).join("\n")
    try {
      fs.writeFileSync(path.join(d, "last-error"),
        `${isoNow()}  ${adapter.advisor} cycle failed: ${run.error ?? "no output"}\n${tail}\n`)
    } catch {}
    append(logPath, `${adapter.advisor} cycle failed: ${run.error ?? "no output"}\n`)
    return 0
  }
  rm(path.join(d, "last-error"))

  // `off` may have been pressed while Codex was thinking. No lock: the epoch
  // captured before the call decides whether any of this is still wanted.
  if (!isEnabled(cwd) || epochOf(cwd) !== startEpoch) { rm(outFile); return 0 }

  const advisories = run.advisories
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
