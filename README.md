# advisor

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
npx skills add pnocera/advisor
```

That installs to `.agents/skills/advisor/` and symlinks it for Claude Code. It does **not** put an
`advisor` command on your PATH, so either use the full path or make a shim:

```bash
ADV=./.agents/skills/advisor/bin/advisor
$ADV link            # optional: puts `advisor` in ~/.local/bin
$ADV doctor          # check dependencies
$ADV install         # merge hooks into .claude/settings.json (existing hooks preserved)
$ADV on              # opt in for this directory
```

**Restart Claude Code after `install`** — hooks are snapshotted at session start, so changes to
`settings.json` do not take effect in a running session.

Requires `codex` (tested on codex-cli 0.147.0), `jq`, and coreutils.

`advisor install user` writes to `~/.claude/settings.json` instead of the project — but it bakes
this checkout's absolute path into your global config, so it refuses to run from a project-local or
temporary location. For a user-scope install, clone the repo somewhere stable and run it from there.
Both scopes back the file up first and write via atomic rename; `advisor uninstall [project|user]`
removes only advisor's own hooks.

## Use

```
advisor on | off                 opt in / out for this directory
advisor quiet on | off           keep analysing and logging, stop injecting
advisor status                   what is enabled, pending, running
advisor log [cwd] [n]            what has been said
advisor tail [cwd]               follow it live
advisor pane [cwd]               Herdr side pane following the log
advisor statusline [cwd]         pending-count segment for your status line
advisor lint <file>              fail if a file reads like a review gate
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
question — no checklist, no categories, no severity rubric. Unguided reviewers find the things a
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

**Delivery is deliberately asymmetric.** `events/` (hook → worker) is at-least-once. `outbox/`
(worker → Claude) is *best effort*, because Claude never acknowledges receiving injected context.
The delivery ledger is written and flushed *before* the emit, so a crash loses an advisory rather
than duplicating one. **The advisor promises you a complete log and promises Claude nothing** —
which is safe precisely because nothing depends on Claude receiving any particular advisory.

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

69 tests: opt-in and immediate-off (including reaping an in-flight cycle and never signalling a
reused PID), the off/publication and drain/off races, quiet, duplicate suppression on replay,
non-Latin fingerprinting, the tap and its debounce, concurrent tap writes, bounded transcript
reading, invocation confinement, install/uninstall merge safety, and hot-path latency.

The concurrency and confinement tests were each verified to **fail** against the pre-fix code. A
test that passes either way is worth nothing — if you change the locking, the fingerprint, the
invocation, or the path resolution, re-check that.

## Provenance

Most of the bugs this code has had were found by pointing the advisor at itself: an `off` that raced
a completing worker, a fingerprint that collapsed every non-Latin note to one, a control lock taken
in an order that made `off` block behind the worker it was stopping, a bare PID that could have
terminated an unrelated process, an `EXIT` trap referencing an out-of-scope variable, and an
`install` that only worked because the author happened to test it with an environment override.

## Licence

MIT
