# Dual-host kibitz design

## Goal

Make one `kibitz` skill package work in both hosts:

- Claude Code is advised by Codex.
- Codex is advised by Claude Code.
- `npx skills` installs the same skill to either or both hosts.
- The advisor remains optional, asynchronous, read-only, and non-blocking.

This is an extension of the current package. It is not a redesign of the
queue, log, epoch, mute, or delivery guarantees.

## Verified host boundary

The installed Codex CLI is 0.147.0. Its hook payloads include `cwd`,
`session_id`, and `transcript_path`. `PostToolUse` also has `tool_name`,
`tool_input`, and `tool_response`. `PreToolUse` and `UserPromptSubmit` can
return `hookSpecificOutput.additionalContext`.

Codex has no `PostToolUseFailure` event. It has an internal `Stop` hook schema,
but this design does not assume that `Stop` is registrable from `hooks.json`.
The implementation must prove that with a live hook before it uses the event.
Its global hook file is `${CODEX_HOME:-~/.codex}/hooks.json` in this
installation.

Claude Code 2.1.227 supports print mode, JSON output, JSON Schema validation,
and tool allow/deny lists. Its exact structured-output envelope must be
captured in the implementation test before the parser is fixed.

## Non-goals

- Do not run a second resident service.
- Do not make advice a review gate.
- Do not inject advice into a shell command.
- Do not let an advisor edit the observed repository.
- Do not merge Claude and Codex session state.
- Do not promise immediate push delivery in Codex. Version one uses the next
  prompt or tool boundary.

## Architecture

```text
Claude Code host                         Codex host
---------------                          ----------
hooks/                                   ~/.codex/hooks.json
  host adapter                              host adapter
       |                                        |
       v                                        v
same queue protocol; host-scoped queue, ledger, epoch, mute, and durable log
       |                                        |
       v                                        v
Codex runner, read-only                    Claude runner, read-only sandbox
       |                                        |
       +----------- normalized advisories -------+
                           |
                           v
          next host input boundary: additionalContext
```

Keep the present atomic file protocol unchanged. The host adapter turns a host
payload and transcript into shared event, context, and delivery operations. The
runner adapter turns the prompt into schema-valid advisory JSON. A runner is
not an observed host session: both runners export `KIBITZ_ADVISOR=1`, and every
kibitz hook returns before it reads or writes state when that variable is set.
A disposable Codex hook must prove the Codex runner preserves it; otherwise use
and test an unstrippable runner marker. This guard applies in both directions
and prevents transitive Claude-to-Codex and Codex-to-Claude recursion. It does
not disable unrelated host hooks.

### Host adapter contract

Define a `HostAdapter` with these fixed responsibilities:

| Operation | Claude Code | Codex |
|---|---|---|
| Hook registration | plugin `hooks/hooks.json`, or explicit `.claude/settings.json` merge | explicit `~/.codex/hooks.json` merge |
| Deliver pending advice | `PreToolUse`, `UserPromptSubmit` | `PreToolUse`, `UserPromptSubmit` |
| Record activity | `PostToolUse`, `PostToolUseFailure` | `PostToolUse` |
| Extract context | Claude JSONL decoder | Codex rollout JSONL decoder |
| Force a cycle | `Stop`, `SubagentStop` | proven `Stop`, else a proven `SubagentStart`, else debounced `PostToolUse`; `PermissionRequest` is supplementary only because auto-approved sessions omit it |
| Reap on end | `SessionEnd` | `SessionEnd` |
| Plugin-root command | `${CLAUDE_PLUGIN_ROOT}/bin/kibitzer` | absolute resolved `bin/kibitzer` path in hooks config |

Normalize each input to `{ cwd, sessionId, transcriptPath, event, tool?,
input?, failure? }`. Infer Codex failure from its `tool_response` only after
fixtures show the stable error shape. Until then, the adapter table's proven
cycle signal is the urgent signal and no heuristic may silently promote a normal
result to a failure.

The shared drain must emit only the host event name that invoked it. It must
not return permission decisions, tool-input rewrites, or a blocking decision.

`readContext(transcriptPath)` is host specific. Each decoder returns the latest
user goal and bounded activity, strips only that host's `⟦kibitz⟧` records, and
reports an unavailable or null transcript explicitly. It must not silently use
the present Claude JSONL parser for Codex rollout records.

Tool classification is also host specific. Each adapter maps its tool names and
result payloads to `read-only`, `mutating`, or `failed`. An unknown Codex tool
is not treated as Claude navigation. Until the real failure payload is pinned,
Codex uses normal `PostToolUse` debounce only.

If Codex cannot live-register `UserPromptSubmit`, its delivery guarantee is the
next proven `PreToolUse` boundary only; `status` must report that degraded mode.

### Runner contract

Replace Codex-specific names with a `RunnerAdapter`.

```ts
interface RunnerAdapter {
  readonly advisor: "codex" | "claude"
  invoke(input: AdvisoryInput, outputFile: string, logFd: number): RunResult
  parse(outputFile: string): Advisory[] | ParseFailure
}
```

`CodexRunner` preserves the existing command and its confinement:

```text
codex exec --sandbox read-only --cd <cwd> --skip-git-repo-check
  --output-schema <schema> -o <file> -
```

`ClaudeRunner` is a fresh print-mode invocation. It receives the same bounded
prompt and the same advisory schema. It must run with all editing and command
tools unavailable. It reads `lib/advice.schema.json`, passes its JSON text
inline to `--json-schema`, and receives the prompt on standard input:

```text
claude --print --output-format json --json-schema <inline-json>
  --safe-mode --tools "" --strict-mcp-config --no-session-persistence -
```

`--safe-mode` must be live-tested to suppress Claude settings, hooks, plugins,
MCP servers, and skills while retaining normal authentication. Do not use
`--dangerously-skip-permissions`,
`bypassPermissions`, or a writable Claude tool set. Do not resume a Claude
conversation. Add `--bare` only if a real fixture proves it preserves the
supported authentication path.

Tool suppression is not a sandbox. The Claude runner needs both a read-only
observed filesystem and outbound network access for its API call. The candidate
is a recorded `bwrap` profile that read-only binds the root, binds only a private
`KIBITZ_RUN_DIR` as writable scratch, and shares the network namespace. It must
prove API success, worktree-write denial, and scratch-write success. Do not run
the whole Claude runner through `codex sandbox`: its current read-only profile
blocks network access. If `codex sandbox` is used for a supporting check, pin
`-c sandbox_mode="read-only"`; never inherit the ambient setting. If no usable
network-capable sandbox is available, fail the Claude runner closed. The
regression suite must try both a built-in write request and a write-capable MCP
path.

For the Claude runner, `outputFile`, logs, and temporary paths must be inside
`KIBITZ_RUN_DIR`, or the parent must open their file descriptors before sandbox
entry. Version one supports the Claude-advisor direction on Linux only; `doctor`
must report a missing usable sandbox and the disabled direction on other
platforms.

The first implementation must pin the actual print-mode JSON envelope in a
recorded fixture. It parses `structured_output`, not the human-readable
`result` string, and accepts a cycle only when `is_error` is false, the subtype
is `success`, and the structured object validates. Missing structured output,
any other subtype, or malformed output fails closed. Record `result` in
`last-error`; publish nothing on a failed Claude cycle, even when the process
exit status is zero.

### Prompt and provenance

Create two short runner preambles, not two divergent prompts:

- The advisor is Claude or Codex, as selected by the runner.
- It is an independent observer, not the host agent.
- It must return advisory JSON only.
- It must not execute commands, change files, or instruct the host.

Keep all task context, activity, diff, schema, de-duplication, and output
fields common. Add a `__HOST_AGENT__` template value so the observer statement
names Claude Code or Codex correctly. Change the rendered banner to name the
actual advisor:
`Advisory from Claude` in Codex sessions and `Advisory from Codex` in Claude
sessions. Retain the untrusted-provenance warning and `⟦kibitz⟧` sentinel.

### State and migration

Use separate host roots:

```text
Claude host: ${CLAUDE_CONFIG_DIR:-~/.claude}/advisor
Codex host:  ${CODEX_HOME:-~/.codex}/advisor
```

Keep `ADVISOR_STATE_ROOT` as an explicit single-host test and migration
override. When it is set, reject `--host all`; a missing selector defaults to
`claude` for legacy compatibility. Add a host marker to every new root. A
marker mismatch rejects use of the root; an existing unmarked root is adopted
as the legacy Claude root. An explicit `--host codex` can mark only an empty
override root; it fails for an unmarked non-empty root. This prevents two host
sessions with the same repository hash and session ID from claiming each
other's output.

The existing Claude state remains byte-compatible. No migration moves it.
Codex starts empty. `kibitzer status` without a host selector reports both
directions.

Control commands take `--host claude|codex|all`; `all` is the default for
`on`, `off`, `quiet`, and mute operations. `off` advances the epoch and clears
pending work in both roots before it returns. A command may select one host for
diagnosis, but it must print that scope. This preserves the existing single
`off` promise when both directions are installed.

### Installation and package layout

Ship one repository and one `skills/kibitz` tree. Add both plugin descriptors:

```text
skills/kibitz/
  SKILL.md
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  hooks/hooks.json
  hooks/codex.json
  install/claude-hooks.json
  install/codex-hooks.json
  src/hosts.ts
  src/runners.ts
```

The exact Codex plugin manifest and component layout must pass the Codex plugin
validator. Do not add unsupported manifest fields merely to point at hooks.
Keep Codex hook discovery as an explicit configuration operation until a clean
plugin install proves automatic hook discovery.

The combined `npx skills` agent syntax is proven with a clean temporary home:

```text
npx skills add pnocera/kibitz -g -a claude-code codex
```

The skills installer makes the skill discoverable in both agents. It does not,
by itself, prove that Codex loaded hooks. On the first Codex use, the skill
runs its installed `bin/kibitzer` by absolute path and calls
`kibitzer install codex-user`. Codex then requires its normal hook-trust
approval for that exact hook file; never bypass trust automatically. The
installer must first capture how an untrusted hook file affects headless
`codex exec`. If it blocks the active Claude-to-Codex runner, installation must
use this safe order: quiet the Claude host, register and approve the Codex hooks
in an interactive Codex session, verify a fresh headless invocation, then
re-enable Claude. Only after trust and a new Codex session can `kibitzer on`
enable the project.

For a one-host installation, the documented agent selector installs only that
host's skill. `kibitzer install claude-project|claude-user|codex-user` and
matching uninstall commands make the target explicit. For this release, bare
`kibitzer install` keeps its present `claude-project` meaning.

Codex configuration is user scoped because the verified hook surface is
`${CODEX_HOME:-~/.codex}/hooks.json`. It remains harmless in projects where
kibitz is off. The installer backs up the file, atomically replaces it, removes
only entries with its exact resolved executable and event, and preserves nested
user hooks. The implementation must use only Codex handler field spellings that
a disposable live hook proves. In particular, it must behaviorally test the
timeout spelling with a short timeout; the current working configuration uses
`timeout`, so it must not assert `timeout_sec` without proof. The configured
context limit must cover the bounded three-advisory drain or the adapter must
reduce its rendered output first.

Claude's legacy hook command stays host-free:
`"${CLAUDE_PLUGIN_ROOT}"/bin/kibitzer hook <Event>`. The exact Codex command
form is `"<resolved>/bin/kibitzer" hook --host codex <Event>`. Ownership
matching accepts the legacy form and this new exact Codex form during upgrade,
so install leaves one entry per event.

### Compatibility decisions

- Retain the `kibitzer` executable name.
- Retain the existing Claude MCP channel as Claude-only. Do not emulate it for
  Codex in this change.
- Keep the current Claude plugin route unchanged for existing installations.
- Add an explicit host argument to every runtime command, test, and diagnostic.
  The legacy Claude hook command is the compatibility exception; its registered
  hook file selects the host. Do not infer host from `PATH` or a CLI binary.
- Reject `advisor == host`. Also keep the runner guard: equal-pair rejection
  cannot prevent a transitive host-hook loop.

## Risks and controls

| Risk | Control |
|---|---|
| Skills install leaves Codex hooks inactive | Document bootstrap separately; prove with clean-home smoke test. |
| Claude print mode can edit or run commands | Use safe mode plus a network-capable read-only sandbox and attempted-write regressions. |
| Claude JSON envelope differs from a raw schema value | Capture a real fixture; reject `is_error`, non-success subtype, and missing structured output. |
| A Codex hook is blocking | Measure hook latency with a sleeping fake Claude runner; require a zero exit on worker-spawn failure. |
| Codex `Stop` is not registrable | Prove live registration before use; otherwise evaluate a proven `SubagentStart`, use `PermissionRequest` only as supplementary activity, then use documented debounced `PostToolUse`. |
| Codex hooks are not trusted | Require normal user trust confirmation; fail closed and never set the bypass flag. |
| A Codex config merge deletes a user hook | Test nested same-event preservation and exact ownership removal. |
| Cross-host queues collide | Use host-specific default roots and marker validation. |
| No usable sandbox exists on this platform | Version one disables the Claude-advisor direction; `doctor` reports the condition. |
| Upgrade breaks present Claude users | Preserve the Claude root, command aliases, old hook recognition, and old queue layout. |
| Advisor calls cost twice in a dual-host project | State the doubled rate and implement a configurable per-host budget or cap in the runner slice. |

## Acceptance criteria

1. A Claude session receives advisory text labelled as Codex advice.
2. A Codex session receives advisory text labelled as Claude advice.
3. Each host's hook path returns quickly while the runner is slow or absent.
4. Default `off` makes concurrent runners and queued advice inert in both
   hosts; a host-specific command affects only its named host.
5. Claude cannot modify the observed worktree during a Codex-host cycle,
   including through configured MCP tools.
6. A user hook in either config file survives install and uninstall.
7. A clean `npx skills` installation into both agents reaches the correct
   bootstrap, trust, and live-hook smoke path for each host.
8. An advisor cycle creates no state in the observed host, and the configured
   per-host advisory budget prevents a further cycle after exhaustion.
