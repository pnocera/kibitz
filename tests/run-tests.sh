#!/usr/bin/env bash
# Phase 1 acceptance tests (01-analysis.md §7, §4.1).
# Uses a throwaway state root; never touches real advisor state and never calls Codex.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADV="$HERE/../skills/advisor/bin/advisor"
export ADVISOR_STATE_ROOT
ADVISOR_STATE_ROOT="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$ADVISOR_STATE_ROOT" "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1" "${3:-}"; fi; }

SID="test-session"
hookjson() { jq -cn --arg c "$WORK" --arg s "$SID" '{cwd:$c, session_id:$s, transcript_path:""}'; }
fire()    { hookjson | "$ADV" hook "$1" 2>/dev/null; }

sdir() {
  local h; h="$(printf '%s' "$WORK" | cksum | tr -d ' ' | cut -c1-12)"
  printf '%s/projects/%s/sessions/%s' "$ADVISOR_STATE_ROOT" "$h" "$SID"
}
pdir() {
  local h; h="$(printf '%s' "$WORK" | cksum | tr -d ' ' | cut -c1-12)"
  printf '%s/projects/%s' "$ADVISOR_STATE_ROOT" "$h"
}

plant() { # plant an advisory directly in the outbox
  mkdir -p "$(sdir)/outbox"
  jq -cn --arg id "$1" --arg n "$2" \
    '{id:$id, note:$n, why_it_matters:"because", evidence:"", confidence:0.9}' \
    >"$(sdir)/outbox/1-$1.json"
}

echo
echo "opt-in and controls"

check "default-off: hooks emit nothing before 'advisor on'" \
  '[ -z "$(fire PreToolUse)" ]' "a hook produced output while disabled"

check "default-off: no state directory is created while disabled" \
  '[ ! -d "$(sdir)" ]' "state created without opt-in"

"$ADV" on "$WORK" >/dev/null
check "on: enabled flag is set" '[ -f "$(pdir)/enabled" ]'

fire UserPromptSubmit >/dev/null
check "on: session state is initialised by the first hook" '[ -d "$(sdir)/outbox" ]'

echo
echo "delivery"

plant id-aaa "first advisory"
out="$(fire PreToolUse)"
check "drain: pending advisory is emitted as additionalContext" \
  '[ -n "$out" ] && printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'

check "drain: emitted block carries the untrusted-provenance banner" \
  'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "UNTRUSTED ADVISORY"'

check "drain: emitted block carries the sentinel for self-filtering" \
  'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "⟦advisor⟧"'

check "drain: hookEventName matches the firing event" \
  '[ "$(printf "%s" "$out" | jq -r ".hookSpecificOutput.hookEventName")" = "PreToolUse" ]'

check "drain: the outbox is empty afterwards" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'

check "drain: delivered id is recorded in the ledger" \
  'grep -qx "id-aaa" "$(sdir)/ledger"'

check "drain: nothing is emitted when the outbox is empty" \
  '[ -z "$(fire PreToolUse)" ]'

# The core of the best-effort contract: a replayed record must never be
# delivered twice, even though the file reappears.
plant id-aaa "first advisory"
check "no duplicate delivery: a replayed record is dropped, not re-emitted" \
  '[ -z "$(fire PreToolUse)" ]' "ledger did not suppress a replay"

plant id-bbb "second advisory"
plant id-ccc "third advisory"
plant id-ddd "fourth advisory"
out="$(fire UserPromptSubmit)"
n="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -c '^- ')"
check "drain: at most ADVISOR_MAX_PER_DRAIN advisories per firing" '[ "$n" -le 3 ]' "emitted $n"

echo
echo "the tap (phase 2)"

toolhook() { # $1 event, $2 tool, $3 error
  jq -cn --arg c "$WORK" --arg s "$SID" --arg t "$2" --arg e "${3:-}" \
    '{cwd:$c, session_id:$s, transcript_path:"", tool_name:$t,
      tool_input:{f:"x.rs"}, tool_response:{error:$e}}' |
    ADVISOR_MIN_INTERVAL=99999 "$ADV" hook "$1" 2>/dev/null
}
evcount() { find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' 2>/dev/null | wc -l; }

# Keep every tap test from spawning a real cycle that would consume its own
# fixtures: a no-op codex on PATH, and a fresh last-cycle so the debounce holds.
NOOP="$WORK/noopcodex"; mkdir -p "$NOOP"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOOP/codex"; chmod +x "$NOOP/codex"
export PATH="$NOOP:$PATH"

"$ADV" on "$WORK" >/dev/null
fire UserPromptSubmit >/dev/null
date +%s >"$(sdir)/last-cycle"
find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' -delete 2>/dev/null
toolhook PostToolUse Read >/dev/null
check "navigation tools do not create events" '[ "$(evcount)" -eq 0 ]'
toolhook PostToolUse Grep >/dev/null; toolhook PostToolUse TodoWrite >/dev/null
check "more navigation still creates nothing" '[ "$(evcount)" -eq 0 ]'

toolhook PostToolUse Edit >/dev/null
check "a mutating tool records one event" '[ "$(evcount)" -eq 1 ]'
toolhook PostToolUse Write >/dev/null
check "events accumulate, one record per file" '[ "$(evcount)" -eq 2 ]'
check "the event captures the tool name" \
  'find "$(sdir)/events" -name "*.json" | xargs -r cat | grep -q "\"Edit\""'

# Concurrent producers: several PostToolUse hooks can run at once, so a shared
# append-only file would interleave. One file per record must survive it.
find "$(sdir)/events" -name '*.json' -delete 2>/dev/null
for i in $(seq 1 25); do toolhook PostToolUse Edit >/dev/null & done; wait
check "25 concurrent tap writes produce 25 intact records" '[ "$(evcount)" -eq 25 ]'
bad=0
for f in "$(sdir)"/events/*.json; do jq -e . "$f" >/dev/null 2>&1 || bad=$((bad+1)); done
check "every concurrently written record is intact JSON" '[ "$bad" -eq 0 ]' "$bad corrupt"

# Debounce: ordinary activity waits, a failure does not.
find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' -delete 2>/dev/null
rm -f "$(sdir)/worker.pid"
# A codex that stalls, so a spawned cycle is observable as "running".
NOSPAWN="$WORK/nospawn"; mkdir -p "$NOSPAWN"
printf '#!/usr/bin/env bash\nsleep 5\n' >"$NOSPAWN/codex"; chmod +x "$NOSPAWN/codex"
date +%s >"$(sdir)/last-cycle"
PATH="$NOSPAWN:$PATH" toolhook PostToolUse Edit >/dev/null; sleep 0.4
check "ordinary activity is debounced, no cycle spawned" \
  '! "$ADV" status "$WORK" | grep -q "codex   : running"'
PATH="$NOSPAWN:$PATH" toolhook PostToolUseFailure Bash "boom" >/dev/null; sleep 0.6
check "a failed tool call bypasses the debounce and spawns immediately" \
  '"$ADV" status "$WORK" | grep -q "codex   : running"' \
  "$("$ADV" status "$WORK" | sed -n "4,8p")"
"$ADV" off "$WORK" >/dev/null
# Wait for the stalled cycle to actually go, rather than guessing at a sleep:
# it holds cycle.lock, and the next test needs to acquire it.
# Wait for the lock itself to free. `off` cannot reap a worker that has not yet
# written its pidfile, so an absent pidfile does not prove the cycle is gone —
# only that we cannot see it. In production that worker exits at its enabled
# re-check; here we just have to let it go.
lock_free() { ( exec 6>"$(sdir)/cycle.lock"; flock -n 6 ); }
for _ in $(seq 1 60); do lock_free && break; sleep 0.25; done
check "no cycle holds the lock once off has settled" 'lock_free'
"$ADV" on "$WORK" >/dev/null
date +%s >"$(sdir)/last-cycle"

# The worker must consume the tap and clear it.
find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' -delete 2>/dev/null
rm -f "$(sdir)/seen"
# Keep last-cycle fresh: clearing it would let this tap call spawn its own
# cycle, which would consume the event before the worker under test sees it.
date +%s >"$(sdir)/last-cycle"
toolhook PostToolUse Edit >/dev/null
CAPBIN="$WORK/capbin"; mkdir -p "$CAPBIN"
cat >"$CAPBIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
cat >"$PROMPTCAP"
[ -n "$out" ] && printf '{"advisories":[]}' >"$out"
exit 0
FAKE
chmod +x "$CAPBIN/codex"
export PROMPTCAP="$WORK/prompt.txt"
PATH="$CAPBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "the worker feeds tap events into the prompt" \
  'grep -q "Tool calls since you last looked" "$PROMPTCAP" && grep -q "Edit" "$PROMPTCAP"'
check "consumed events are cleared, not replayed forever" '[ "$(evcount)" -eq 0 ]'
check "an empty advisory list publishes nothing" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'

echo
echo "quiet"

"$ADV" quiet on "$WORK" >/dev/null
plant id-quiet "should not be injected"
check "quiet: nothing is injected" '[ -z "$(fire PreToolUse)" ]'
check "quiet: the advisory is still pending, not discarded" \
  '[ -n "$(find "$(sdir)/outbox" -name "*.json")" ]'
"$ADV" quiet off "$WORK" >/dev/null
check "quiet off: injection resumes" '[ -n "$(fire PreToolUse)" ]'

echo
echo "off"

plant id-eee "pending when off is pressed"
"$ADV" off "$WORK" >/dev/null
check "off: enabled flag is cleared" '[ ! -f "$(pdir)/enabled" ]'
check "off: pending advisories are cleared, not left to leak later" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'
check "no-advice-after-off: hooks emit nothing" '[ -z "$(fire PreToolUse)" ]'

# A worker stalled inside Codex, i.e. before its publication phase.
STALLBIN="$WORK/stallbin"; mkdir -p "$STALLBIN"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$STALLBIN/codex"; chmod +x "$STALLBIN/codex"

"$ADV" on "$WORK" >/dev/null
PATH="$STALLBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1 &
WPID=$!
sleep 0.5
"$ADV" off "$WORK" >/dev/null
sleep 0.3
check "immediate-off: a genuine in-flight worker is reaped" \
  '! kill -0 "$WPID" 2>/dev/null' "worker survived off"
wait "$WPID" 2>/dev/null

# A stale pidfile whose number the kernel has since handed to something else
# must never be signalled. The previous version of this test planted an
# arbitrary pid and asserted it WAS killed — it was asserting the bug.
"$ADV" on "$WORK" >/dev/null
mkdir -p "$(sdir)"
sleep 30 & BYSTANDER=$!
printf '%s 999999999\n' "$BYSTANDER" >"$(sdir)/worker.pid"   # right pid, wrong start time
"$ADV" off "$WORK" >/dev/null
sleep 0.2
check "off never signals a pid that is not our worker" \
  'kill -0 "$BYSTANDER" 2>/dev/null' "an unrelated process was terminated"
kill "$BYSTANDER" 2>/dev/null; wait "$BYSTANDER" 2>/dev/null

# The guarantee is that DISABLING is immediate, even when an unreapable worker
# still holds the control lock for its publication. `off` may wait to clean up;
# nothing may reach Claude in the meantime.
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen"
SLOWBIN="$WORK/slowbin"; mkdir -p "$SLOWBIN"
cat >"$SLOWBIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && jq -cn '{advisories: [range(0;400) | {note:"slow \(.)", why_it_matters:"t", evidence:"", confidence:0.5}]}' >"$out"
exit 0
FAKE
chmod +x "$SLOWBIN/codex"
PATH="$SLOWBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1 &
WPID=$!
sleep 0.5
rm -f "$(sdir)/worker.pid"          # unreapable: force the lock path
"$ADV" off "$WORK" >/dev/null 2>&1 &
OFFPID=$!
sleep 0.2                            # off has cleared the flag but may still be waiting
check "disabling takes effect immediately even while off waits on a publication" \
  '[ -z "$(fire PreToolUse)" ]' "advice was still injected after off began"
wait "$OFFPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "off still cleans up everything the stalled worker published" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'

echo
echo "off races a completing worker  (found by the advisor, on itself)"

# A worker that has already passed its enabled check must not be able to publish
# after `off` has cleared the outbox. Fake codex stalls so `off` lands inside the
# worker's publication window.
# The window between the worker's enabled re-check and its renames is microseconds
# for a single record, so a one-record test cannot land inside it and passes
# whether or not the lock exists. Emit many records to widen the publication
# phase into something `off` can reliably land in the middle of.
RACEBIN="$WORK/racebin"; mkdir -p "$RACEBIN"
cat >"$RACEBIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
sleep 0.2
[ -n "$out" ] && jq -cn '{advisories: [range(0;300) | {note:"race \(.)", why_it_matters:"t", evidence:"", confidence:0.5}]}' >"$out"
exit 0
FAKE
chmod +x "$RACEBIN/codex"

"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen"
PATH="$RACEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1 &
WPID=$!
sleep 0.4
# Drop the pid file so `off` cannot reap this worker. This models the real
# window the Stop hook opens on every cycle — the worker exists before it has
# written worker.pid — and isolates what is actually under test: killing is an
# optimisation, the control lock is the correctness mechanism. Without the lock
# an unreapable worker publishes straight past off's clear.
rm -f "$(sdir)/worker.pid"
sleep 0.2                       # codex has returned; worker is mid-publication
"$ADV" off "$WORK" >/dev/null
wait "$WPID" 2>/dev/null

check "no advisory survives an off that races publication" \
  '[ -z "$(find "$(sdir)/outbox" "$(sdir)/outbox-processing" -name "*.json" 2>/dev/null)" ]' \
  "a record was published after off cleared the outbox"
check "no-advice-after-off holds after the race" '[ -z "$(fire PreToolUse)" ]'

echo
echo "drain races off  (found by the advisor, on itself)"

# A drain that has already passed cmd_hook's enabled check must not claim and
# emit after `off` has removed the flag. Simulated by disabling between the
# outer check and the drain: with the under-lock re-check, nothing is emitted.
# Land `off` *inside* the window between cmd_hook's enabled check and the drain,
# using the ADVISOR_TEST_DRAIN_DELAY seam. Clearing the flag before the hook runs
# would only exercise cmd_hook's own check and prove nothing about the drain.
"$ADV" on "$WORK" >/dev/null
plant id-drainrace "must not escape after off"
RACEOUT="$WORK/drainrace.out"
( hookjson | ADVISOR_TEST_DRAIN_DELAY=0.6 "$ADV" hook PreToolUse >"$RACEOUT" 2>/dev/null ) &
DPID=$!
sleep 0.2
rm -f "$(pdir)/enabled"           # off's first action, while the drain is in flight
wait "$DPID" 2>/dev/null
check "a drain already past the outer check emits nothing once off lands" \
  '[ ! -s "$RACEOUT" ]' "advice escaped after the flag was cleared: $(cat "$RACEOUT" 2>/dev/null)"
check "the record is not silently consumed either" \
  '[ -n "$(find "$(sdir)/outbox" "$(sdir)/outbox-processing" -name "*.json" 2>/dev/null)" ]'
"$ADV" off "$WORK" >/dev/null; "$ADV" on "$WORK" >/dev/null

# The drain must never block the hot path behind a publishing worker.
exec 9>"$(pdir)/control.lock"; flock 9        # simulate a worker holding it
plant id-locked "waiting behind a publication"
t0=$(date +%s%N); out="$(fire PreToolUse)"; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
check "drain does not block when the control lock is held (${ms}ms)" '[ "$ms" -lt 300 ]' "${ms}ms"
check "drain defers rather than emitting while the lock is held" '[ -z "$out" ]'
flock -u 9; exec 9>&-
check "the deferred advisory is delivered on the next call" '[ -n "$(fire PreToolUse)" ]'

echo
echo "transcript is read bounded, not slurped  (found by the advisor, on itself)"

BIGT="$WORK/big-transcript.jsonl"
: >"$BIGT"
for i in $(seq 1 4000); do
  jq -cn --arg t "entry $i padding: $(head -c 200 /dev/zero | tr '\0' 'x')" \
    '{isSidechain:false, message:{role:"user", content:[{type:"text", text:$t}]}}' >>"$BIGT"
done
BYTES=$(wc -c <"$BIGT")
# A no-op codex, so the measurement is the context build and nothing else.
NOOPBIN="$WORK/noopbin"; mkdir -p "$NOOPBIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOOPBIN/codex"; chmod +x "$NOOPBIN/codex"
# Time it rather than counting syscalls: slurping a multi-MB transcript is
# markedly slower than a bounded tail, and this stays portable.
t0=$(date +%s%N)
PATH="$NOOPBIN:$PATH" ADVISOR_TRANSCRIPT_LINES=400 "$ADV" worker "$WORK" "$SID" "$BIGT" >/dev/null 2>&1
t1=$(date +%s%N)
check "a ${BYTES}-byte transcript is processed in bounded time ($(( (t1-t0)/1000000 ))ms)" \
  '[ "$(( (t1-t0)/1000000 ))" -lt 4000 ]'
check "context builder reads only the configured tail" \
  'grep -q "tail -n \"\$TRANSCRIPT_LINES\"" "$ADV"'

echo
echo "deduplication"

"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen"
UNIBIN="$WORK/unibin"; mkdir -p "$UNIBIN"
cat >"$UNIBIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && cat >"$out" <<'JSON'
{"advisories":[
 {"note":"競合状態がここにあります","why_it_matters":"a","evidence":"","confidence":0.9},
 {"note":"Кэш не инвалидируется","why_it_matters":"b","evidence":"","confidence":0.9}
]}
JSON
exit 0
FAKE
chmod +x "$UNIBIN/codex"
PATH="$UNIBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
n="$(find "$(sdir)/outbox" -name '*.json' 2>/dev/null | wc -l)"
check "two distinct non-Latin advisories are not collapsed into one" \
  '[ "$n" -eq 2 ]' "published $n of 2 — fingerprint is lossy for non-ASCII"

# And identical notes still deduplicate.
rm -f "$(sdir)/outbox"/*.json
PATH="$UNIBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "a repeated advisory is still suppressed" \
  '[ "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null | wc -l)" -eq 0 ]'

# off must clear the producer queue too, or re-enabling resurrects activity the
# operator opted out of.
"$ADV" on "$WORK" >/dev/null
date +%s >"$(sdir)/last-cycle"
find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' -delete 2>/dev/null
toolhook PostToolUse Edit >/dev/null
check "tap recorded an event before off" '[ "$(evcount)" -eq 1 ]'
"$ADV" off "$WORK" >/dev/null
check "off clears the event queue, not just the outbox" '[ "$(evcount)" -eq 0 ]' \
  "pre-off activity would feed the next cycle after re-enabling"
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen"; date +%s >"$(sdir)/last-cycle"
: >"$PROMPTCAP"
PATH="$CAPBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "a cycle after off->on sees no pre-off activity" \
  '! grep -q "Edit" "$PROMPTCAP"' "$(grep -A3 "Tool calls" "$PROMPTCAP" 2>/dev/null | head -4)"

# An in-flight tap hook must not publish after off has cleared the queues.
"$ADV" on "$WORK" >/dev/null
date +%s >"$(sdir)/last-cycle"
find "$(sdir)/events" "$(sdir)/events-processing" -name '*.json' -delete 2>/dev/null
( jq -cn --arg c "$WORK" --arg s "$SID" \
    '{cwd:$c, session_id:$s, transcript_path:"", tool_name:"Edit",
      tool_input:{f:"x.rs"}, tool_response:{error:""}}' |
  ADVISOR_TEST_TAP_DELAY=0.6 ADVISOR_MIN_INTERVAL=99999 "$ADV" hook PostToolUse >/dev/null 2>&1 ) &
TPID=$!
sleep 0.2
"$ADV" off "$WORK" >/dev/null
wait "$TPID" 2>/dev/null
check "an in-flight tap hook publishes nothing once off lands" \
  '[ "$(evcount)" -eq 0 ]' "a tap event was written after off cleared the queues"

echo
echo "install through a symlink  (found by the advisor, on itself)"

# ADVISOR_HOME must come from the *resolved* script path. Invoked via a symlink
# with no override -- the documented entrypoint -- the sibling lib/ and
# hooks.json must still be found.
LINKROOT="$WORK/linkroot"; mkdir -p "$LINKROOT"
ln -sfn "$HERE/../skills/advisor/bin" "$LINKROOT/bin"
( cd "$LINKROOT" && ./bin/advisor doctor ) >"$WORK/doctor.out" 2>&1
check "doctor finds schema and prompt through a symlinked bin/" \
  '! grep -q "MISS" "$WORK/doctor.out"' "$(cat "$WORK/doctor.out")"

INSTDIR="$WORK/instproj"; mkdir -p "$INSTDIR"
( cd "$INSTDIR" && "$LINKROOT/bin/advisor" install project ) >"$WORK/install.out" 2>&1
check "install works through a symlink with no ADVISOR_HOME override" \
  '[ -f "$INSTDIR/.claude/settings.json" ]' "$(cat "$WORK/install.out")"
check "install registers the tap events too" \
  'jq -e ".hooks.PostToolUse and .hooks.PostToolUseFailure and .hooks.Stop" "$INSTDIR/.claude/settings.json" >/dev/null'
check "installed commands point at the real script, not the symlink dir" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep -q "skills/advisor/bin/advisor"'

# Existing hooks must survive, and uninstall must put things back.
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"model":"x"}\n' \
  >"$INSTDIR/.claude/settings.json"
( cd "$INSTDIR" && "$LINKROOT/bin/advisor" install project ) >/dev/null 2>&1
check "install preserves a pre-existing hook on the same event" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep -q "echo mine"'
check "install preserves unrelated settings" \
  '[ "$(jq -r ".model" "$INSTDIR/.claude/settings.json")" = "x" ]'
( cd "$INSTDIR" && "$LINKROOT/bin/advisor" uninstall project ) >/dev/null 2>&1
check "uninstall removes only our hooks" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep -q "echo mine" &&
   ! jq -r ".hooks | tostring" "$INSTDIR/.claude/settings.json" | grep -q "advisor hook"'

echo
echo "register (decision 7)"

check "no gate language in the prompt sent to Codex" \
  '"$ADV" lint "$HERE/../skills/advisor/lib/prompt.tmpl" >/dev/null'
check "no severity or verdict field in the advice schema" \
  '! jq -e ".. | objects | has(\"severity\") or has(\"verdict\")" "$HERE/../skills/advisor/lib/advice.schema.json" | grep -q true'
check "schema permits an empty advisory list" \
  '[ "$(jq -r ".properties.advisories.minItems // 0" "$HERE/../skills/advisor/lib/advice.schema.json")" = "0" ]'

echo
echo "confinement (01-analysis.md §6.2) — captures the real invocation"

# Stand a fake `codex` in front of the worker and record exactly how it is
# invoked. This is the acceptance test §6.2 asks for: it fails on any cycle that
# omits the confinement flags, and on any use of the unconfinable resume path.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CAPTURE"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '{"advisories":[{"note":"captured","why_it_matters":"t","evidence":"","confidence":0.5}]}' >"$out"
exit 0
FAKE
chmod +x "$FAKEBIN/codex"
export CAPTURE="$WORK/capture.txt"; : >"$CAPTURE"

"$ADV" on "$WORK" >/dev/null
PATH="$FAKEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1

check "worker actually invoked codex" '[ -s "$CAPTURE" ]'
check "every invocation passes --sandbox read-only" \
  '! grep -qv -- "--sandbox read-only" "$CAPTURE"' "$(cat "$CAPTURE")"
check "every invocation passes --cd for the session cwd" \
  "! grep -qv -- \"--cd $WORK\" \"\$CAPTURE\"" "$(cat "$CAPTURE")"
check "no invocation uses the unconfinable 'resume' subcommand" \
  '! grep -qw "resume" "$CAPTURE"' "resume reintroduced; see §6.2"
check "worker published the advisory it received" \
  '[ -n "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'
check "worker wrote to the durable operator log" \
  'grep -q "captured" "$(sdir)/advice.log"'

# The operator log is a delivery-independent record of truth: advisories reach it
# even when Claude is never given them.
"$ADV" quiet on "$WORK" >/dev/null
: >"$CAPTURE"; rm -f "$(sdir)/seen"
PATH="$FAKEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "operator log records advisories even while injection is quiet" \
  '[ "$(grep -c "captured" "$(sdir)/advice.log")" -ge 2 ]'
"$ADV" quiet off "$WORK" >/dev/null

echo
echo "hot path"

t0=$(date +%s%N); fire PreToolUse >/dev/null; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
check "drain hook completes well inside the 2s hook budget (${ms}ms)" '[ "$ms" -lt 500 ]' "${ms}ms"

echo
printf '  %s passed, %s failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
