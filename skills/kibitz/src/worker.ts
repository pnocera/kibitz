// One Codex cycle. Detached by the hook, so nothing here is on the hot path --
// but everything here is subject to the epoch: `off` during a cycle must make
// the whole cycle inert, including anything it is about to publish.

import { spawnSync } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import * as fs from "node:fs"
import * as path from "node:path"
import {
  BIN, ISSUE_LIFECYCLE_V1, Issue, IssueState, OperationPhase, PROMPT_TMPL,
  ageMinutes, append, appendSync, citedPaths, claimTokens, epochOf, initSess,
  isEnabled, isMuted, isoNow, issueKey, issueStateMap, outcomeMap, pathsSignature, readIssues, repeatedIssue,
  validFreshness, validTiming,
  currentHost, listJson, read, rm, validSid, writeWorkerPid,
} from "./core.ts"
import { adapterFor, inferPhase, observeEvent, renderFacts } from "./hosts.ts"
import { invokeRunner, reserveCycle } from "./runners.ts"

/** Digest the whole normalised note. Projecting onto [a-z0-9] collapses any
 *  note written entirely in non-Latin script to the empty string, making every
 *  such advisory a duplicate of the first. */
const fingerprint = (s: string) =>
  createHash("sha1").update(s.toLowerCase().replace(/\s+/g, " ")).digest("hex")

const timingRank = (timing: string, freshness: string) =>
  (timing === "now" && freshness === "current_activity") ? 0
    : timing === "now" ? 1 : timing === "before_next_mutation" ? 2
      : timing === "milestone" ? 3 : 4

const advisoryCap = () => {
  const configured = Number(process.env.ADVISOR_MAX_PER_CYCLE)
  if (Number.isFinite(configured) && configured > 0) return Math.floor(configured)
  return currentHost() === "codex" && ISSUE_LIFECYCLE_V1 ? 1 : Number.POSITIVE_INFINITY
}

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

  const observations: any[] = []
  for (const f of listJson(path.join(d, "events-processing"))) {
    let e: any
    try { e = JSON.parse(read(f) ?? "") } catch { rm(f); continue }
    if (String(e.epoch ?? 0) !== startEpoch) { rm(f); continue }   // previous epoch
    observations.push(observeEvent(e))
  }
  const events = observations.slice(-60).map(o =>
    `${o.at ?? "now"}  ${o.tool} (${o.command_class})  ${o.input}${o.error ? `\n    ERROR: ${o.error}` : ""}`).join("\n")
    || "(no tool activity recorded since the last look)"
  const facts = renderFacts(observations)
  const phase: OperationPhase = inferPhase(observations)

  const prompt = (read(PROMPT_TMPL) ?? "")
    .split("__CWD__").join(cwd)
    .split("__GOAL__").join(goal)
    .split("__ACTIVITY__").join(activity)
    .split("__EVENTS__").join(events)
    .split("__FACTS__").join(facts)
    .split("__PHASE__").join(phase)
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

  // Rank before publishing. The advisor may return several thoughts, but an
  // ordinary Codex boundary gets one interruption; separate current-activity
  // `now` hazards may occupy the remaining two slots.
  const advisories = [...run.advisories].sort((a, b) => timingRank(String(a?.timing ?? "deferred"), String(a?.evidence_freshness ?? "historical_context"))
    - timingRank(String(b?.timing ?? "deferred"), String(b?.evidence_freshness ?? "historical_context")))
  const seenPath = path.join(d, "seen")
  const seen = new Set((read(seenPath) ?? "").split("\n").filter(Boolean))
  // Identity is decided here, on the one path both directions publish through:
  // Codex advising Claude and Claude advising Codex differ only in the runner
  // upstream of this loop.
  const issues = readIssues(d)
  const outcomes = outcomeMap(d)
  const states = issueStateMap(d)
  const outcomeOf = (id: string) => outcomes.get(id)?.outcome
  const latestByKey = new Map<string, Issue>()
  for (const issue of issues) if (issue.key) latestByKey.set(issue.key, issue)
  let n = 0
  let repeats = 0
  const cap = advisoryCap()

  for (const a of advisories) {
    const note = a?.note ?? ""
    if (!note) continue
    const kind = a?.kind ?? ""
    const evidence = a?.evidence ?? ""
    if (isMuted(cwd, `${kind} ${note} ${evidence}`)) continue
    const fp = fingerprint(note)
    const paths = citedPaths(evidence, cwd)
    const tokens = claimTokens(`${note} ${a?.why_it_matters ?? ""}`)
    const hasStableClaim = typeof a?.claim === "string" && a.claim.trim() !== ""
    const lifecycle = ISSUE_LIFECYCLE_V1 && hasStableClaim
    const claim = hasStableClaim ? a.claim.trim() : note
    const timing = validTiming(a?.timing) ? a.timing : "deferred"
    const freshness = validFreshness(a?.evidence_freshness) ? a.evidence_freshness : "historical_context"
    const sig = pathsSignature(cwd, paths)
    const key = issueKey(claim, cwd, paths)
    const existing = lifecycle ? latestByKey.get(key) : undefined
    const existingState: IssueState = existing ? (states.get(existing.id)?.state ?? "open") : "open"
    const milestoneReached = timing === "milestone" && phase === "restore" && existing?.phase !== "restore"
    const evidenceChanged = Boolean(existing && existing.sig !== sig)
    const staleLifecycle = Boolean(existing && !evidenceChanged && !milestoneReached)
    const already = !lifecycle ? repeatedIssue({ tokens, paths }, issues, cwd, outcomeOf) : undefined

    // Exact prose remains a backstop for the legacy policy. Lifecycle mode
    // deliberately permits the same claim at a new evidence/milestone boundary.
    if (!lifecycle && seen.has(fp)) continue
    if (existing && existingState === "declined") {
      append(path.join(d, "suppressions.jsonl"), JSON.stringify({ id: existing.id, at: isoNow(), reason: "declined" }) + "\n")
      repeats++; continue
    }
    if (staleLifecycle || already) {
      const id = existing?.id ?? already!.id
      const reason = staleLifecycle ? "unchanged_open" : "legacy_repeat"
      append(logPath, `repeat of ${id.slice(0, 6)} (${reason}); not publishing it again\n`)
      append(path.join(d, "repeats"), `${id}\n`)
      append(path.join(d, "suppressions.jsonl"), JSON.stringify({ id, at: isoNow(), reason }) + "\n")
      repeats++
      continue
    }
    // At most one ordinary result per Codex boundary. A new current-activity
    // `now` risk may still interrupt alongside it, up to the existing drain cap.
    const urgentNow = timing === "now" && freshness === "current_activity"
    if (n >= cap && !(urgentNow && n < 3)) {
      append(path.join(d, "suppressions.jsonl"), JSON.stringify({ at: isoNow(), reason: "delivery_cap", claim }) + "\n")
      continue
    }

    const id = existing?.id ?? randomUUID()
    const deliveryId = randomUUID()
    const short = id.slice(0, 6)
    const rec = {
      id: deliveryId, issue_id: id, epoch: Number(startEpoch), kind, note, claim, timing, evidence_freshness: freshness, phase,
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
    // The short id is in the log because the log is what an operator reads, and
    // the outbox record that also carries it is deleted on delivery. Without it
    // here, nothing can name this advisory once it has been read.
    let entry = `\n[${t}] ${short} ${kind ? `(${kind})` : ""} ${note}\n`
    if (rec.why_it_matters) entry += `   why: ${rec.why_it_matters}\n`
    if (rec.evidence) entry += `   ref: ${rec.evidence}\n`
    if (!appendSync(path.join(d, "advice.log"), entry)) {
      append(logPath, `could not log ${id}; not publishing it\n`)
      continue
    }
    // The register keeps the whole id and the log shows its first six, the way
    // a commit is quoted short but stored long: a six-character collision would
    // otherwise make both advisories permanently unaddressable, with no longer
    // form anywhere for an operator to fall back on.
    const issue: Issue = {
      id, at: isoNow(), kind, fp,
      tokens: [...tokens], paths, sig, key, claim, scope: cwd, timing, evidence_freshness: freshness, phase,
    }
    // Before the outbox and before `seen`, for the same reason the log comes
    // before both: this file is what makes a paraphrase a repeat on the next
    // cycle and what `mark` resolves an id against. Publishing an advisory that
    // no register records means an id in the log that resolves to nothing and a
    // repeat the next worker cannot recognise -- so an unregistered advisory is
    // not published, exactly as an unlogged one is not.
    if (!appendSync(path.join(d, "issues.jsonl"), JSON.stringify(issue) + "\n")) {
      append(logPath, `could not register ${short}; not publishing it\n`)
      continue
    }
    issues.push(issue); latestByKey.set(key, issue)
    if (existing && (evidenceChanged || milestoneReached)) {
      appendSync(path.join(d, "issue-events.jsonl"), JSON.stringify({ id, state: "open", at: isoNow(),
        reason: evidenceChanged ? "fresh evidence" : "restore milestone" }) + "\n")
    }
    // Suppress a repeat only once the advisory is actually recorded. Marking it
    // seen first turns a transient failure into permanent omission: the advisory
    // is never published, never registered, and deduplicated away for the rest
    // of the session once the disk recovers.
    seen.add(fp)
    append(seenPath, fp + "\n")
    append(path.join(d, "kinds"), (kind || "unlabelled") + "\n")

    const tmp = path.join(d, "tmp", `${deliveryId}.json`)
    try {
      fs.writeFileSync(tmp, JSON.stringify(rec))
      fs.renameSync(tmp, path.join(d, "outbox", `${Math.floor(Date.now() / 1000)}-${deliveryId}.json`))
    } catch { rm(tmp); continue }
    n++
  }
  append(logPath, `published ${n} of ${advisories.length}${repeats ? `, ${repeats} repeat(s) held back` : ""}\n`)
  rm(outFile)
  // Consumed successfully: drop the claim.
  for (const f of listJson(path.join(d, "events-processing"))) rm(f)
  return 0
}
