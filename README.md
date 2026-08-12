# kibitz

**Cross-host advisory: Codex for Claude Code, and Claude for Codex.**

While either host works, a detached observer watches the session, tool activity, and working tree.
Claude Code uses a read-only Codex runner. Codex uses a tool-disabled Claude runner in a
network-capable read-only Linux sandbox. Advice is injected at the next supported input boundary
and written to a durable log.

It is **advisory, not review**: no verdicts, no severities, no pass/fail, and it blocks nothing.
Claude decides what is worth acting on; you see everything either way.

```
Claude Code hook ─► Codex runner ─┐
                                  ├─► host-scoped outbox ─► next input boundary
Codex hook ──────► Claude runner ─┘    (hooks never block)  └─► advice.log
```

## Install

```bash
npx skills add pnocera/kibitz -g -a claude-code codex
```

Restart Claude Code, then ask it to opt in for the current directory:

> run `kibitzer on`

Claude Code ships hooks through its plugin. Codex needs one more activation step after its skill is
installed: run `~/.agents/skills/kibitz/bin/kibitzer install codex-user`, approve Codex's normal
hook-trust prompt, and start a new Codex session. Do not use a trust-bypass flag. Registration
rewrites `hooks.json` after creating a `.kibitz-backup`; existing Codex hooks can require
re-approval. The skills installer makes a skill visible; it does not itself activate Codex hooks.

Claude Code exposes the plugin's `bin/` directory on its Bash-tool `PATH`, so its agents can run
`kibitzer`. In a terminal or another host, use the installed path or run its `link` command once
to make a shell command:

```bash
~/.claude/skills/kibitz/bin/kibitzer link   # creates ~/.local/bin/kibitzer
```

Named kibitz because Claude Code already has a built-in `/advisor`, and shadowing it is a bad idea.
(A kibitzer is someone who watches over your shoulder and offers unsolicited advice.)

The skill is `/kibitz`; the executable is **`kibitzer`**. `/usr/bin/kibitz` is expect(1)'s utility on
most Debian/Ubuntu systems, and a plugin's `bin/` does not win over `/usr/bin`, so naming the
executable `kibitz` means the wrong program runs. If `kibitzer` is shadowed on your machine, call it
by path: `~/.claude/skills/kibitz/bin/kibitzer`.

**Why those selectors.** `-a claude-code codex` installs only to the two supported agents. Without
them the installer can link the skill into every agent directory it knows about. `-g` installs to
`~/.claude/skills/kibitz` and `~/.agents/skills/kibitz`, which load in every project. A project-scope
install instead lands in an agent-specific project directory and loads only after its workspace-trust
dialog is accepted.

To update: `npx skills update -g`.

Requires [Bun](https://bun.sh) (tested on 1.3.14, which is what CI pins), `codex` (tested on
codex-cli 0.147.0), and coreutils. The Codex-host direction also needs authenticated `claude`,
`bwrap`, and Linux with user namespaces enabled.

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
temporary checkout, since it bakes an absolute path into your global config. The installed
`.../bin/kibitzer link` command puts the command on your `PATH`. None of this is needed for a plugin
install.

</details>

## Use

In Claude Code, the plugin exposes `kibitzer` on the Bash-tool `PATH`; the
commands below use that form. Codex uses the installed path stated immediately
after the block.

```
kibitzer on | off [cwd] [--host H]       opt in / out for this directory
kibitzer quiet on | off [--host H]       keep analysing and logging, stop injecting
kibitzer status [cwd] [--host H]         what is enabled, pending, running
kibitzer log [cwd] [n]                   what has been said
kibitzer tail [cwd]                      follow it live
kibitzer pane [cwd]                      Herdr side pane following the log
kibitzer statusline [cwd]                pending-count segment for your status line
kibitzer advise-now [cwd]                ask for a contribution now, without waiting
kibitzer mute <text>|list|clear          stop hearing about a topic
kibitzer stats [cwd]                     what kinds of things it has been saying
kibitzer lint <file>                     fail if a file reads like a review gate
kibitzer install codex-user              register user-scoped Codex hooks
```

These are the Claude Code commands. In Codex, invoke the equivalent installed executable at
`~/.agents/skills/kibitz/bin/kibitzer`; after running its `link` command once, `kibitzer` is also
available from `~/.local/bin`.

Use `--host claude` or `--host codex` for one direction. Controls (`on`, `off`, `quiet`, and
`status`) without a host selector act on both installed hosts. Session-specific commands (`log`,
`tail`, `stats`, and `advise-now`) default to Claude; pass `--host codex` for a Codex session.
Default is **off**, per directory. `off` is immediate: it disables, reaps in-flight work, and
clears pending advice and the tap queue.

## Behaviour

**When it looks.** In Claude Code, turn endings and failed tool calls trigger a cycle immediately.
In Codex, only live-proven hook events are used and normal post-tool activity is debounced
(`ADVISOR_MIN_INTERVAL`, default 45s). Known non-mutating built-in tools do not trigger one;
shell commands are observed because they can mutate. Only one cycle runs at a time per session.

**What it sees.** A bounded transcript tail (`ADVISOR_TRANSCRIPT_LINES`, default 400), tool calls
since the last cycle, and `git diff`. The Codex advisor can inspect the repository read-only. The
Claude advisor receives only that bounded material because its tools are disabled.

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
Claude never acknowledges receiving injected context. Delivery is committed *before* the emit — by
creating a per-id marker with `O_EXCL`, which exactly one consumer can do whatever the timing — so a
crash loses an advisory rather than duplicating one. This is also why `status` says *claimed* rather
than *emitted*: the marker records that we took responsibility for an advisory, not that anyone saw
it. **The advisor promises you a complete log and promises Claude nothing** — which is safe precisely
because nothing depends on Claude receiving any particular advisory.

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
session. A skills-directory plugin is loaded for MCP but is not a channel-installable marketplace
plugin, so register this channel once as a named user MCP server:

```bash
claude mcp add --scope user kibitz-channel -- \
  ~/.claude/skills/kibitz/bin/kibitzer channel
```

Then restart Claude with the named development channel:

```bash
claude --dangerously-load-development-channels server:kibitz-channel
```

Accept the development-channel confirmation. `/mcp` should show
`kibitz-channel` connected. Do not pass `plugin:kibitz@skills-dir` or either
`plugin:kibitz:kibitz` form to the channel flag: those identify the skills-dir
plugin/MCP server but are not an installed channel plugin.

It is a **second consumer of the same queue**, not a replacement. It takes the same atomic per-id
claim, and that claim — not the ledger, which is a readable record and may fail to be written — is
what stops the two ever both delivering one advisory. Whichever is running does the work. With no
channel loaded nothing changes.

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

176 tests: opt-in and immediate-off (including reaping an in-flight cycle and never signalling a
reused PID), the off/publication and drain/off races, quiet, duplicate suppression on replay,
non-Latin fingerprinting, the tap and its debounce, concurrent tap writes, bounded transcript
reading, invocation confinement, the plugin package (manifest, hook events, relocatable
`${CLAUDE_PLUGIN_ROOT}` paths), install/uninstall merge safety including hooks nested beside yours,
upgrade from the two-file state layout, epoch boundaries across off/on, mute at both publication and
delivery, the channel's MCP handshake and its parity with the hook drain, and hot-path latency.

`tests/smoke-plugin.sh --host claude` is separate and opt-in, and `SMOKE_CHANNEL=1` adds a second phase that
queues an advisory and checks a real Claude launched with the development-channel flag actually
claims it — the unit tests can prove the queue logic and the `.mcp.json` shape, but not that Claude
discovers and launches the channel. The base phase: it installs into the real layout, starts a headless
Claude Code, and asserts a hook actually fired. It uses an owner-only temporary copy of the local
Claude credentials file (or `KIBITZ_CLAUDE_CREDENTIALS_JSON`) for its disposable config. A token
refresh can require logging in again afterwards. It needs an authenticated CLI and a couple of
minutes, so CI cannot run it — but the JSON-shape tests never cross the loader boundary, and this
package has already shipped one install that validated perfectly and loaded nothing.

`bash tests/smoke-npx-skills.sh` checks the published combined `npx skills` command in a clean
home and verifies both installed layouts plus Codex hook registration. `--live` adds the two host
loader checks; the Codex half needs an interactive terminal and uses an owner-only temporary copy
of the existing local Codex login because it needs a disposable `CODEX_HOME` for normal hook-trust
approval. A token refresh in either disposable login can require signing in again afterwards.

Run `bash tests/dual-host.sh` with the legacy suite after changing host selection, Codex hooks,
state roots, or runner boundaries. CI runs both suites.

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
