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
npx skills add -g -a claude-code pnocera/kibitz
```

Restart Claude Code, then ask it to opt in for the current directory:

> run `kibitzer on`

That is the whole installation. kibitz ships as a Claude Code **plugin**, so the hooks come with it:
nothing to merge into `settings.json`.

Note that `kibitzer` is on **Claude Code's Bash tool** `PATH`, not your shell's — that is what plugins
expose. Asking Claude to run it works; typing it in your own terminal will not, unless you use the
full path or run `kibitzer link`:

```bash
~/.claude/skills/kibitz/bin/kibitzer on     # or: ... link, for a ~/.local/bin shim
```

Named kibitz because Claude Code already has a built-in `/advisor`, and shadowing it is a bad idea.
(A kibitzer is someone who watches over your shoulder and offers unsolicited advice.)

The skill is `/kibitz`; the executable is **`kibitzer`**. `/usr/bin/kibitz` is expect(1)'s utility on
most Debian/Ubuntu systems, and a plugin's `bin/` does not win over `/usr/bin`, so naming the
executable `kibitz` means the wrong program runs. If `kibitzer` is shadowed on your machine, call it
by path: `~/.claude/skills/kibitz/bin/kibitzer`.

**Why those two flags.** `-a claude-code` matters: without it the installer symlinks the skill into
every agent directory it knows about — around fifty of them — and kibitz is useless to all of them,
since its hooks are Claude Code's mechanism. `-g` installs to `~/.claude/skills/kibitz`, which loads
in every project. A project-scope install instead lands in `.claude/skills/kibitz`, which loads only
after you accept the workspace trust dialog and only when Claude Code starts from that exact
directory.

To update: `npx skills update -g`.

Requires [Bun](https://bun.sh) (tested on 1.3.14, which is what CI pins), `codex` (tested on
codex-cli 0.147.0), and coreutils.

**Bun must be on the PATH Claude Code gives its hooks.** It is the interpreter in the
executable's shebang, so without it a hook fails before any of kibitz's own error handling
runs. `kibitzer doctor` checks for it first.

<details>
<summary>Registering hooks by hand instead</summary>

For a checkout that does not live in a skills directory, `kibitzer install` merges hooks into
`settings.json`, preserving anything already there, and `kibitzer uninstall` removes only its own.

If you registered hooks with a build from before the executable was renamed, those entries point at
a `bin/kibitz` that no longer exists and are no longer recognised as ours. Delete just those
entries by hand — the ones whose command contains `/bin/kibitz hook` — then run `kibitzer install`.
Do not clear the whole `hooks` block: it holds your other hooks too.
`kibitzer install user` targets `~/.claude/settings.json` but refuses to run from a project-local or
temporary checkout, since it bakes an absolute path into your global config. `kibitzer link` puts the
command on your `PATH`. None of this is needed for a plugin install.

</details>

## Use

```
kibitzer on | off                 opt in / out for this directory
kibitzer quiet on | off           keep analysing and logging, stop injecting
kibitzer status                   what is enabled, pending, running
kibitzer log [cwd] [n]            what has been said
kibitzer tail [cwd]               follow it live
kibitzer pane [cwd]               Herdr side pane following the log
kibitzer statusline [cwd]         pending-count segment for your status line
kibitzer advise-now [cwd]         ask for a contribution now, without waiting
kibitzer mute <text>|list|clear   stop hearing about a topic
kibitzer stats [cwd]              what kinds of things it has been saying
kibitzer lint <file>              fail if a file reads like a review gate
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
question — no checklist, no categories, no severity rubric.
Unguided reviewers find the things a checklist would never list; a checklist turns the reviewer into
a checklist executor. The output schema has no `severity` and no `verdict` field, deliberately: a
severity enum is a review rubric wearing a JSON hat.

It does say explicitly that the range is wider than fault-finding: a simpler approach, an unexamined
assumption, something worth preserving. Each advisory carries a free-text `kind` in Codex's own
words, and `kibitzer stats` counts them, so whether the constructive half actually materialises is
measured rather than assumed.

**What it costs you.** At most 3 advisories per tool call. Hooks do file I/O only and run in tens of
milliseconds against Claude Code's 2s budget; the Codex call is fully detached and never blocks a
turn.

## Design notes

**Hooks never block.** Every hook is a file append or a file read, always exits 0, and spawns work
with `setsid`. A hook that waited on Codex would freeze the session. Measured cost: ~23 ms idle,
~48 ms when it delivers, against Claude Code's 2 s budget.

**TypeScript on Bun.** It replaced 927 lines of shell, and is faster on the hot path than the shell
was — the shell paid a `jq` subprocess per field per record. Most defects this code has had were
shell-shaped: `case` alternation that silently never matched, `IFS` collapsing empty fields, `$?`
read after the wrong command, `grep -q` with `pipefail`.

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

## Pushing instead of waiting (optional)

By default an advisory waits for your next tool call. That is seconds during active work, but an
advisory produced while the session sits idle waits until you do something.

kibitz also ships a Claude Code **channel** — an MCP server that pushes advisories into the running
session. Channels are a research preview and custom ones are not allowlisted, so it needs a launch
flag:

```bash
claude --dangerously-load-development-channels server:kibitz
```

That flag prints a **WARNING: Loading development channels** banner naming `server:kibitz`. This is
expected and is not an error — it is the consent notice for the flag, and the channel loads.

Do not try to avoid the banner by dropping the flag and passing `--channels server:kibitz`. A
`server:` entry always requires the development flag, and without it the entry is **skipped
silently**: Claude starts with no channel and tells you nothing. You lose the push and are not
warned.

`--channels` takes only `plugin:<name>@<marketplace>` entries, against an allowlist that is either
Anthropic's own or `allowedChannelPlugins` in **managed** settings. On an ordinary workstation
kibitz is on neither, so the flag above is the way to run it. An administrator who allowlists
`plugin:kibitz@<marketplace>` in managed settings can run it through `--channels` without the
banner; that route is untested here.

It is a **second consumer of the same queue**, not a replacement. It claims records by the same
atomic rename and writes the same ledger, so the two can never both deliver one advisory, and
whichever is running does the work. With no channel loaded nothing changes.

It does not add an acknowledgement. Claude Code does not acknowledge channel notifications, and an
unregistered or policy-blocked channel drops them silently, so the contract is unchanged: lose
rather than duplicate, with `advice.log` as the record of truth.

Claude Code does not tell an MCP server which session it serves, so the channel works it out from
its own process ancestry against Claude's session registry. If it cannot, it **declines to push**
and the hook drain delivers as usual — pushing one session's advisory into another session would be
a wrong-recipient failure, not merely a late delivery. Set `KIBITZ_SESSION` to bind it by hand.

## Tests

```bash
bash tests/run-tests.sh
```

170 tests: opt-in and immediate-off (including reaping an in-flight cycle and never signalling a
reused PID), the off/publication and drain/off races, quiet, duplicate suppression on replay,
non-Latin fingerprinting, the tap and its debounce, concurrent tap writes, bounded transcript
reading, invocation confinement, the plugin package (manifest, hook events, relocatable
`${CLAUDE_PLUGIN_ROOT}` paths), install/uninstall merge safety including hooks nested beside yours,
upgrade from the two-file state layout, epoch boundaries across off/on, mute at both publication and
delivery, the channel's MCP handshake and its parity with the hook drain, and hot-path latency.

`tests/smoke-plugin.sh` is separate and opt-in, and `SMOKE_CHANNEL=1` adds a second phase that
queues an advisory and checks a real Claude launched with the development-channel flag actually
claims it — the unit tests can prove the queue logic and the `.mcp.json` shape, but not that Claude
discovers and launches the channel. The base phase: it installs into the real layout, starts a headless
Claude Code, and asserts a hook actually fired. It needs an authenticated CLI and a couple of
minutes, so CI cannot run it — but the JSON-shape tests never cross the loader boundary, and this
package has already shipped one install that validated perfectly and loaded nothing.

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
