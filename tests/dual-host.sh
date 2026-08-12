#!/usr/bin/env bash
# Dual-host regression coverage. Uses fake advisor binaries; no network call.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ADV="$HERE/../skills/kibitz/bin/kibitzer"
TMP="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$TMP/claude"
CODEX_HOME="$TMP/codex"
WORK="$TMP/work"
HOME="$TMP/home"
export CLAUDE_CONFIG_DIR CODEX_HOME HOME
mkdir -p "$WORK" "$HOME"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

sid=dual-session
payload() { jq -cn --arg cwd "$WORK" --arg sid "$sid" '{cwd:$cwd,session_id:$sid,transcript_path:""}'; }
hash() { printf '%s' "$WORK" | cksum | tr -d ' ' | cut -c1-12; }
claude_project="$CLAUDE_CONFIG_DIR/advisor/projects/$(hash)"
codex_project="$CODEX_HOME/advisor/projects/$(hash)"
codex_session="$codex_project/sessions/$sid"
FIXTURE="$HERE/fixtures/codex-rollout.jsonl"

echo
echo "dual host"

# The guard must return before it parses payload or creates session state.
payload | KIBITZ_ADVISOR=1 "$ADV" hook --host codex UserPromptSubmit >/dev/null
check "runner guard creates no Codex project state" '[ ! -e "$CODEX_HOME/advisor/projects/$(hash)" ]'

"$ADV" on --host claude "$WORK" >/dev/null
"$ADV" on --host codex "$WORK" >/dev/null
check "hosts use separate state roots" '[ -f "$CLAUDE_CONFIG_DIR/advisor/host" ] && [ -f "$CODEX_HOME/advisor/host" ]'
check "host markers are explicit" '[ "$(cat "$CLAUDE_CONFIG_DIR/advisor/host")" = claude ] && [ "$(cat "$CODEX_HOME/advisor/host")" = codex ]'

CTRL="$TMP/control"
mkdir -p "$CTRL/claude/advisor"
printf '%s\n' codex >"$CTRL/claude/advisor/host"
CLAUDE_CONFIG_DIR="$CTRL/claude" CODEX_HOME="$CTRL/codex" "$ADV" on "$WORK" >/dev/null 2>&1 || true
check "a failed Claude host does not skip Codex control" '[ -f "$CTRL/codex/advisor/projects/$(hash)/state" ]'

payload | ADVISOR_MIN_INTERVAL=99999 "$ADV" hook --host codex UserPromptSubmit >/dev/null
codex_payload() { jq -cn --arg cwd "$WORK" --arg sid "$sid" --arg transcript "$FIXTURE" '{cwd:$cwd,session_id:$sid,transcript_path:$transcript,tool_name:"shell"}'; }
codex_payload | ADVISOR_MIN_INTERVAL=99999 "$ADV" hook --host codex UserPromptSubmit >/dev/null
check "Codex hook preserves transcript for advise-now" '[ "$(cat "$codex_session/transcript")" = "$FIXTURE" ]'
mkdir -p "$codex_session/outbox"
epoch="$(cut -d' ' -f2 "$codex_project/state")"
jq -cn --argjson epoch "$epoch" '{id:"codex-advice",epoch:$epoch,note:"Claude advice",kind:"",why_it_matters:"",evidence:""}' >"$codex_session/outbox/one.json"
out="$(payload | "$ADV" hook --host codex PreToolUse)"
check "Codex host labels delivery as Claude advice" 'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "UNTRUSTED ADVISORY from Claude"'
check "Codex host returns Codex hook output" '[ "$(printf "%s" "$out" | jq -r ".hookSpecificOutput.hookEventName")" = PreToolUse ]'

mkdir -p "$CODEX_HOME"
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo foreign","timeout":1}]}]}}' >"$CODEX_HOME/hooks.json"
"$ADV" install codex-user >/dev/null
check "Codex install preserves a foreign hook" 'grep -F "\"command\": \"echo foreign\"" "$CODEX_HOME/hooks.json" >/dev/null'
check "Codex install writes the explicit host command" 'grep -F "hook --host codex PreToolUse" "$CODEX_HOME/hooks.json" >/dev/null'
"$ADV" uninstall codex-user >/dev/null
check "Codex uninstall preserves the foreign hook" 'grep -F "\"command\": \"echo foreign\"" "$CODEX_HOME/hooks.json" >/dev/null'
check "Codex uninstall removes the owned command" '! grep -F "hook --host codex" "$CODEX_HOME/hooks.json" >/dev/null'

MANAGED="$TMP/.agents/skills/kibitz"
mkdir -p "$(dirname "$MANAGED")"
cp -a "$HERE/../skills/kibitz" "$MANAGED"
MANAGED_CODEX="$TMP/managed-codex"
CODEX_HOME="$MANAGED_CODEX" "$MANAGED/bin/kibitzer" install codex-user >/dev/null
check "managed skills install activates Codex without force" '[ "$(jq ".hooks | keys | length" "$MANAGED_CODEX/hooks.json")" = 4 ]'

TRANSIENT="$TMP/transient/kibitz"
mkdir -p "$(dirname "$TRANSIENT")"
cp -a "$HERE/../skills/kibitz" "$TRANSIENT"
CODEX_HOME="$TMP/transient-codex" "$TRANSIENT/bin/kibitzer" install codex-user >"$TMP/transient-install" 2>&1 || true
check "transient Codex install gives a Codex-specific remedy" 'grep -F "install codex-user --force" "$TMP/transient-install" >/dev/null && ! grep -F "install claude-project" "$TMP/transient-install" >/dev/null'

if bun -e 'import { adapterFor } from "'"$HERE"'/../skills/kibitz/src/hosts.ts"; const c = adapterFor("codex").readContext(process.argv[1]); if (!c.activity.includes("I will update") || !c.activity.includes("functions.exec") || c.activity.includes("boilerplate")) process.exit(1)' "$FIXTURE"; then context_rc=0; else context_rc=$?; fi
check "Codex rollout decoder keeps assistant and tool activity only" '[ "$context_rc" -eq 0 ]'

events_before="$(find "$codex_session/events" -name '*.json' 2>/dev/null | wc -l)"
jq -cn --arg cwd "$WORK" --arg sid "$sid" '{cwd:$cwd,session_id:$sid,tool_name:"web_search",tool_input:{}}' \
  | "$ADV" hook --host codex PostToolUse >/dev/null
check "Codex built-in navigation does not create an event" '[ "$(find "$codex_session/events" -name "*.json" 2>/dev/null | wc -l)" = "$events_before" ]'

# A fake bwrap is sufficient to test the Claude JSON-envelope consumer. The
# real profile is exercised separately by the authenticated smoke test.
FAKE="$TMP/fake"
mkdir -p "$FAKE"
printf '%s\n' '#!/usr/bin/env bash' 'cat >"$BWRAP_CAPTURE"' "printf '%s\n' '{\"is_error\":false,\"subtype\":\"success\",\"structured_output\":{\"advisories\":[]}}'" >"$FAKE/bwrap"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$FAKE/claude"
chmod +x "$FAKE/bwrap" "$FAKE/claude"
BWRAP_CAPTURE="$TMP/claude-prompt" PATH="$FAKE:$PATH" "$ADV" worker --host codex "$WORK" "$sid" "" "$(cut -d' ' -f2 "$codex_project/state")" >/dev/null
check "Claude structured envelope is accepted" '! test -s "$codex_session/last-error"'
check "Claude prompt does not claim repository access" 'grep -F "You can use only the material below" "$TMP/claude-prompt" >/dev/null && ! grep -F "Read the repository yourself" "$TMP/claude-prompt" >/dev/null'

STATE_HOME="$TMP/state-home"
LEGACY="$STATE_HOME/.claude/advisor/projects/$(hash)"
mkdir -p "$LEGACY"
printf '1 4\n' >"$LEGACY/state"
HOME="$STATE_HOME" CLAUDE_CONFIG_DIR="$TMP/alternate-claude" "$ADV" status --host claude "$WORK" >"$TMP/migrated-status"
check "Claude config override keeps an enabled legacy root" 'grep -F "enabled : yes" "$TMP/migrated-status" >/dev/null'
PATH="$FAKE:$PATH" "$ADV" doctor --host codex >"$TMP/doctor"
check "doctor reports Claude runner dependencies" 'grep -F "claude" "$TMP/doctor" >/dev/null && grep -F "bwrap" "$TMP/doctor" >/dev/null'

LEAN="$TMP/lean-bin"
mkdir -p "$LEAN"
# `codex` is deliberately absent from this minimal PATH: doctor must regard the
# unregistered Codex direction as optional. It is available to local developers
# but not on the GitHub runner, so only link commands that actually exist.
for tool in bun codex flock setsid timeout tail find; do
  tool_path="$(command -v "$tool" || true)"
  [ -z "$tool_path" ] || ln -s "$tool_path" "$LEAN/$tool"
done
DOCTOR_HOME="$TMP/doctor-home"
DOCTOR_CODEX="$TMP/doctor-codex"
DOCTOR_CLAUDE="$TMP/doctor-claude"
mkdir -p "$DOCTOR_HOME"
env HOME="$DOCTOR_HOME" CODEX_HOME="$DOCTOR_CODEX" CLAUDE_CONFIG_DIR="$DOCTOR_CLAUDE" PATH="$LEAN" "$ADV" doctor >/dev/null
doctor_initial_rc=$?
check "bare doctor treats an unregistered Codex direction as optional" '[ "$doctor_initial_rc" -eq 0 ]'
env HOME="$DOCTOR_HOME" CODEX_HOME="$DOCTOR_CODEX" CLAUDE_CONFIG_DIR="$DOCTOR_CLAUDE" PATH="$LEAN" "$ADV" install codex-user >/dev/null
if env HOME="$DOCTOR_HOME" CODEX_HOME="$DOCTOR_CODEX" CLAUDE_CONFIG_DIR="$DOCTOR_CLAUDE" PATH="$LEAN" "$ADV" doctor >/dev/null 2>&1; then doctor_rc=0; else doctor_rc=$?; fi
check "bare doctor requires Claude runner after Codex registration" '[ "$doctor_rc" -eq 1 ]'

if [ "$fail" -ne 0 ]; then
  printf '\n%d dual-host tests failed\n' "$fail" >&2
  exit 1
fi
printf '\n%d dual-host tests passed\n' "$pass"
