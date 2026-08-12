# Dual-host kibitz implementation plan

## Scope and order

Implement in small, reversible slices. Do not change the present Claude
runtime until the shared abstractions have direct regression coverage.

## 1. Capture current external contracts

Files: new `tests/fixtures/`, new `work/` evidence note if needed.

1. Capture a real Codex hook payload and transcript for `PreToolUse`,
   `PostToolUse`, `UserPromptSubmit`, and `SessionEnd` in a disposable
   `CODEX_HOME`; prove that `UserPromptSubmit` registers and fires.
2. Capture one successful and one failed Codex `PostToolUse.tool_response`.
3. Capture the real Codex rollout JSONL shape and derive a bounded context
   fixture with a user goal and activity item.
4. Capture a real Claude print-mode response with inline `--json-schema` JSON.
5. Record the exact Claude `--safe-mode` command that disables built-in tools,
   MCP tools, settings, plugins, skills, and hooks while retaining normal API
   authentication.
6. Record an exact network-capable sandbox command. It must prove Claude API
   success, observed-worktree write denial, and private scratch write success.
   It must place the Claude output, log, and temporary paths in that scratch
   directory, capture `permission_denials`, and repeat with the real bounded
   prompt. If `codex sandbox` is tested, pin `sandbox_mode="read-only"`
   explicitly.
7. Prove a runner `KIBITZ_ADVISOR=1` value reaches a disposable Codex child
   hook. If it does not, capture and use an unstrippable replacement marker.
8. Behaviorally test each Codex hook-handler field spelling, including a short
   timeout that proves the selected timeout field is honoured.
9. Capture how an untrusted Codex hook file affects headless `codex exec`.
   Record the safe install order if it blocks an active Claude runner.
10. Prove whether a `Stop` entry in `hooks.json` fires. If not, evaluate
   `PermissionRequest` and `SubagentStart`, then record the debounced
   `PostToolUse` fallback.
11. Test a disposable Codex hooks file to confirm reload and the required
   trust approval flow.

Gate: no parser or Codex failure classifier is implemented from help text or
binary strings alone.

## 2. Extract shared host-neutral logic

Files: `skills/kibitz/src/core.ts`, `hooks.ts`, `worker.ts`, new `hosts.ts`,
new `runners.ts`, `bin/kibitzer`.

1. Add explicit `Host` and `Advisor` types.
2. Move event normalization, tool classification, event selection, and
   transcript decoding to `HostAdapter`.
3. Move process launch and output decoding to `RunnerAdapter`.
4. Keep queue publication, epochs, leases, ledger claims, mute checks, and log
   first/publish second unchanged.
5. Pass host and advisor through the worker command. Reject invalid or equal
   pairs before making state. Set the proven runner marker in every runner and
   return from kibitz `runHook` before state access when it is present. Do not
   claim that unrelated host hooks are disabled by this guard.
6. Add host-specific state-root selection with `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
   and the existing test override preserved. Write and validate host markers;
   adopt an unmarked legacy root as Claude state.
7. Add `--host claude|codex|all` control semantics. Make `all` the default for
   control commands and show both directions in unscoped status. With
   `ADVISOR_STATE_ROOT`, reject `all` and default a missing selector to Claude.
   Missing per-host roots must not prevent a default-all control from reporting
   the result for its other host.
8. Change status and diagnostics from `codex` to `advisor` plus explicit host.

Gate: the current Claude-host/Codex-runner suite still passes without changing
its event fixture payloads.

## 3. Add the Codex host adapter

Files: new `hooks/codex.json`, new `install/codex-hooks.json`, `hosts.ts`,
`hooks.ts`.

1. Register `PreToolUse` and `UserPromptSubmit` for drain only after their
   individual live-registration gates pass. If `UserPromptSubmit` fails, retain
   `PreToolUse` delivery only and report the degraded talk-only guarantee.
2. Register `PostToolUse` for activity; use the captured failure form only.
3. Register `Stop` for an urgent turn-end cycle only after the live registration
   gate passes. Otherwise evaluate live `SubagentStart`; use
   `PermissionRequest` only as supplementary activity because auto-approved
   sessions omit it. If neither is suitable, document and implement debounced
   `PostToolUse`.
4. Register `SessionEnd` for reaping.
5. Add `SubagentStop` only after a live payload and delivery test prove it is
   useful and separate from the parent `Stop` path.
6. Use only the Codex handler object shape proven in the external-contract
   capture, and exact per-event ownership matching; do not reuse the Claude
   template shape.
7. Ensure all commands use one resolved executable path and preserve the
   command's quoting rules.
8. Make an adapter output `hookSpecificOutput` with the actual Codex event
   name and no decision field.

Gate: invalid payload, invalid session ID, missing `setsid`, slow runner, and
runner-spawn failure all leave the Codex host turn non-blocking.

## 4. Add the Claude runner

Files: `runners.ts`, `worker.ts`, `lib/prompt.tmpl`, new runner fixture tests.

1. Implement the captured Claude print-mode command with inline schema JSON,
   prompt on standard input, safe mode, disabled built-in tools, strict empty
   MCP config, fresh session, bounded timeout, and logged output.
2. Decode only the captured structured-output envelope. Treat `is_error`, a
   non-success subtype, or missing structured output as failure even if Claude
   exits zero; record `result` in `last-error`.
3. Feed it through the current schema validation before publication.
4. Label output and errors as `claude`, without changing the Codex runner.
5. Add the host-specific banner and `__HOST_AGENT__` prompt substitution while
   retaining the untrusted advisory text.
6. Run the Claude process in the proven OS read-only, network-capable sandbox.
   If no usable profile exists, fail closed. Implement a configurable per-host
   advisory budget or cap in this slice. Version one supports this runner only
   on Linux; `doctor` must report a missing sandbox and disabled direction.
7. Test a malicious prompt and a write-capable MCP fixture; prove neither can
   change tracked or untracked repository files.

Gate: success publishes one well-formed advisory; malformed output, a timeout,
and non-zero exit publish none and set `last-error`.

## 5. Make configuration mutation host-aware

Files: `src/install.ts`, `src/core.ts`, `install/claude-hooks.json`,
`install/codex-hooks.json`, `src/commands.ts`.

1. Split install targets into `claude-project`, `claude-user`, and
   `codex-user`, resolving the last target from `CODEX_HOME`.
2. Keep `claude-project` as the compatibility meaning of `install project` and
   bare `install` for this release.
3. Add exact ownership matching per host and event. Never remove a wrapper
   that merely contains the word `kibitzer`. Accept the legacy host-free Claude
   hook form and the exact new Codex `--host codex` form; an upgrade must leave
   exactly one entry per event.
4. Use backup plus same-directory temporary file plus rename for both JSON
   configurations.
5. Update `doctor` to report the host, selected runner, command availability,
   correct hook file, registered hook events, and hook-trust state. Never
   provide an automatic trust-bypass path.
6. If external-contract capture finds that untrusted hooks block headless
   `codex exec`, make installation quiet the Claude host before registration,
   require interactive trust approval and a fresh headless check, then allow
   re-enablement.

Gate: install and uninstall preserve unrelated fields and a user command that
shares the same event group in each host's JSON file.

## 6. Package and skill updates

Files: `SKILL.md`, `README.md`, `.codex-plugin/plugin.json`,
`.claude-plugin/plugin.json`, `hooks/hooks.json`, package tests.

1. Add the Codex plugin descriptor with valid metadata only.
2. Keep Claude's descriptor and `hooks/hooks.json` discovery path compatible
   with the installed package layout; do not rename it without an explicit
   manifest hook path and a fresh Claude plugin smoke test.
3. Update the skill's trigger text and commands for both host directions.
4. Document the three-stage Codex path: `npx skills` makes the skill visible;
   `kibitzer install codex-user` registers hooks; the operator trusts them and
   starts a new session.
5. Verify the combined installer syntax before documenting it. Until then,
   document separate one-host commands only.
6. State that the Claude channel is not available in Codex mode.

Gate: each agent sees only accurate commands for its host. No documentation
claims that `npx skills` alone activates Codex hooks unless the clean smoke
test proves that behavior.

## 7. Test matrix

Extend `tests/run-tests.sh` with host parameterization. Keep existing Claude
tests as independent coverage; do not replace them with a loop that can hide
host-specific assertions.

| Test area | Claude host / Codex advisor | Codex host / Claude advisor |
|---|---|---|
| Add context | `PreToolUse`, `UserPromptSubmit` | `PreToolUse`, `UserPromptSubmit` |
| Activity | post-success and post-failure | post-success and captured failure |
| Cycle start | stop and subagent stop | proven stop, else proven subagent signal; permission is supplementary; else debounced post-tool |
| Session end | process tree reaped | process tree reaped |
| Runner | existing read-only command | Linux OS sandbox, disabled tools/MCP, scratch output, no-write proof |
| Queue state | legacy root adopted and marked | isolated `${CODEX_HOME:-~/.codex}` root |
| Controls | default all-host control, scoped result, missing-root tolerance | default all-host control, scoped result, missing-root tolerance |
| Install merge | `.claude/settings.json` | `${CODEX_HOME:-~/.codex}/hooks.json` |
| Package smoke | real Claude plugin loader | real Codex hook loader |

Required mutation tests:

1. Remove the final epoch check: the off-race test fails in both hosts.
2. Remove the delivery marker claim: duplicate-drain test fails.
3. Remove Claude's disabled-tools option: write-attempt test fails.
4. Remove the runner guard: an advisor invocation creates a host session or
   changes `current-session`, and the recursion test fails.
5. Replace the Codex context decoder with the Claude decoder: the Codex rollout
   fixture test fails.
6. Change a Codex hook event name: package or live smoke test fails.
7. Broaden uninstall ownership matching: foreign-wrapper preservation test
   fails.
8. Remove safe mode or the sandbox: the hostile user-hook, API, or write-proof
   test fails.
9. Make Claude return an `is_error` envelope with exit zero: publication is
   rejected and `last-error` is set.
10. Set `ADVISOR_STATE_ROOT` with `--host all`: command rejection test fails;
    remove one default root and confirm the other host result still prints.
11. Remove the new per-host cap: the budget-exhaustion test fails.
12. Upgrade a legacy hook command to the new Codex form: exactly-one-entry
    assertion fails if ownership matching is not backward compatible.

## 8. Live smoke tests

Add opt-in tests, separate from CI:

```text
bash tests/smoke-plugin.sh --host claude
bash tests/smoke-plugin.sh --host codex
bash tests/smoke-npx-skills.sh --live
```

The Codex smoke test must use a disposable `CODEX_HOME`, install the hook file,
perform normal hook trust approval, start a real Codex session, and prove the
right host state was created. It must separately prove `Stop` registration or
the documented fallback and record the effect of untrusted hooks on headless
`codex exec`. The combined skills smoke test must install into a
clean temporary home, check both skills are discoverable, verify the agent
selector syntax, perform each host bootstrap, and run both live hook assertions.

## 9. Release gate

1. Run the full unit suite.
2. Run `bunx tsc --noEmit` or the repository's equivalent type check.
3. Validate both plugin manifests with their host validators.
4. Run the two host smoke tests with authenticated CLIs.
5. Run `git diff --check`.
6. Update the README version and supported CLI versions only after all live
   loader checks pass.

## Deferred work

- A Codex push channel or notification path.
- A shared cross-host dashboard.
- Automatic hook registration by the `skills` installer.
- Reusing a persistent advisor conversation.
