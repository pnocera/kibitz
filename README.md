# kibitz

**Codex as a background advisory process for Claude Code.**

While Claude Code works, a detached `codex exec` watches the session — tool activity, turn endings,
the working tree — and offers whatever it thinks is worth saying. Its remarks are injected into
Claude's context at the next tool call, and always written to a durable log you can watch live.

It is **advisory, not review**: no verdicts, no severities, no pass/fail, and it blocks nothing.
Claude decides what is worth acting on; you see everything either way.

```
tool activity ─► hook ─► events/ ─┐
turn ends ────► hook ─────────────┴─► detached codex exec ─┬─► outbox/ ─► next tool call ─► Claude
                (≤50ms, never blocks)                      └─► advice.log ─► you
```

## Install

```bash
npx skills add pnocera/kibitz
```

Named kibitz because Claude Code already has a built-in `/advisor`, and shadowing it is a bad idea.
(A kibitzer is someone who watches over your shoulder and offers unsolicited advice.)

That installs to `.agents/skills/kibitz/` and symlinks it for Claude Code. It does **not** put a
`kibitz` command on your PATH, so either use the full path or make a shim:

```bash
K=./.agents/skills/kibitz/bin/kibitz
$K link              # optional: puts `kibitz` in ~/.local/bin
$K doctor            # check dependencies
$K install           # merge hooks into .claude/settings.json (existing hooks preserved)
$K on                # opt in for this directory
```

To update later: `npx skills update` (`-p` for project scope, `-g` for global).

**Restart Claude Code after `install`** — hooks are snapshotted at session start, so changes to
`settings.json` do not take effect in a running session.

Requires `codex` (tested on codex-cli 0.147.0), `jq`, and coreutils.

`kibitz install user` writes to `~/.claude/settings.json` instead of the project — but it bakes
this checkout's absolute path into your global config, so it refuses to run from a project-local or
temporary location. For a user-scope install, clone the repo somewhere stable and run it from there.
Both scopes back the file up first and write via atomic rename; `kibitz uninstall [project|user]`
removes only kibitz's own hooks.

## Use

```
kibitz on | off                 opt in / out for this directory
kibitz quiet on | off           keep analysing and logging, stop injecting
kibitz status                   what is enabled, pending, running
kibitz log [cwd] [n]            what has been said
kibitz tail [cwd]               follow it live
kibitz pane [cwd]               Herdr side pane following the log
kibitz statusline [cwd]         pending-count segment for your status line
kibitz advise-now [cwd]         ask for a contribution now, without waiting
kibitz mute <text>|list|clear   stop hearing about a topic
kibitz stats [cwd]              what kinds of things it has been saying
kibitz lint <file>              fail if a file reads like a review gate
```

Default is **off**, per directory. `off` is immediate: it disables, reaps any in-flight Codex, and
clears pending advice and the tap queue.

## Behaviour

**When it looks.** Turn endings and failed tool calls always trigger a cycle. Ordinary edits are
debounced (`ADVISOR_MIN_INTERVAL`, default 45s). Read-only tools never trigger one. Only one cycle
runs at a time per session.

**What it sees.** A bounded tail of the transcript (`ADVISOR_TRANSCRIPT_LINES`, default 400), the
tool calls since the last cycle, and `git diff`. It reads the repository itself; the summary is a
pointer, not a source.

**What it is told.** As little as possible. The prompt gives Codex the situation and one open
question — no checklist, no categories, no severity rubric. It does say explicitly that the range is
wider than fault-finding: a simpler approach, an unexamined assumption, something worth preserving.
Each advisory carries a free-text `kind` in Codex's own words, and `kibitz stats` counts them, so
whether the constructive half actually materialises is measured rather than assumed. Unguided reviewers find the things a
checklist would never list; a checklist turns the reviewer into a checklist executor. The output
schema has no `severity` and no `verdict` field, deliberately: a severity enum is a review rubric
wearing a JSON hat.

**What it costs you.** At most 3 advisories per tool call. Hooks do file I/O only and run in tens of
milliseconds against Claude Code's 2s budget; the Codex call is fully detached and never blocks a
turn.

## Design notes

**Hooks never block.** Every hook is a file append or a file read, always exits 0, and spawns work
with `setsid`. A hook that waited on Codex would freeze the session.

**One record per file, published by atomic rename.** Claude runs matching hooks in parallel and a
turn can issue parallel tool calls, so several producers write at once. A shared append-only file
would interleave.

**Delivery is deliberately asymmetric.** `outbox/` (worker → Claude) is *best effort*, because
Claude never acknowledges receiving injected context. The delivery ledger is written and flushed
*before* the emit, so a crash loses an advisory rather than duplicating one. **The advisor promises
you a complete log and promises Claude nothing** — which is safe precisely because nothing depends
on Claude receiving any particular advisory.

**Opt-out is an epoch, not a lock.** `enabled` and an epoch counter live in one file, replaced
atomically; `off` advances the epoch, every record carries the epoch it was born in, and consumers
ignore older ones. Locks were tried first and were the wrong tool: producers, the worker and the
drain are separate processes, and an exclusive lock across them serialised producers, dropped events
under contention, leaked a descriptor through `setsid` into a detached child, and wedged delivery
silently for as long as any holder lived. An epoch has none of those failure modes — a late writer
is harmless because its output is already inert.

The honest residual: `off` and a drain already past its final check are not perfectly linearizable.
The window is a single stat, an advisory already being rendered may still land, and it blocks
nothing. Closing it completely would mean reintroducing the critical section that caused a total
delivery outage.

**Every cycle is a fresh, confined invocation:** `codex exec --sandbox read-only --cd <cwd>`.
Do **not** switch to `codex exec resume` — it accepts neither flag on 0.147.0, so it cannot hold the
confinement boundary, and cost is not a good enough reason to give that up. The test suite captures
the real invocation and fails if this regresses.

**Advice is untrusted.** It is derived from repository content, which may itself be adversarial.
Injected blocks carry a provenance banner, Codex runs read-only, and advisory text never reaches a
shell.

## Tests

```bash
bash tests/run-tests.sh
```

82 tests: opt-in and immediate-off (including reaping an in-flight cycle and never signalling a
reused PID), the off/publication and drain/off races, quiet, duplicate suppression on replay,
non-Latin fingerprinting, the tap and its debounce, concurrent tap writes, bounded transcript
reading, invocation confinement, install/uninstall merge safety, epoch boundaries across off/on, mute at both
publication and delivery, and hot-path latency.

The concurrency and confinement tests were each verified to **fail** against the pre-fix code. A
test that passes either way is worth nothing — if you change the locking, the fingerprint, the
invocation, or the path resolution, re-check that.

## Provenance

Most of the bugs this code has had were found by pointing kibitz at itself: an `off` that raced
a completing worker, a fingerprint that collapsed every non-Latin note to one, a control lock taken
in an order that made `off` block behind the worker it was stopping, a bare PID that could have
terminated an unrelated process, an `EXIT` trap referencing an out-of-scope variable, and an
`install` that only worked because the author happened to test it with an environment override.

## Licence

MIT
