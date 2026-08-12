#!/usr/bin/env bash
# Phase 1 acceptance tests (01-analysis.md §7, §4.1).
# Uses a throwaway state root; never touches real advisor state and never calls Codex.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADV="${KIBITZ_BIN:-$HERE/../skills/kibitz/bin/kibitzer}"
PLUG="$(cd "$(dirname "$ADV")/.." && pwd)"
export ADVISOR_STATE_ROOT
ADVISOR_STATE_ROOT="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$ADVISOR_STATE_ROOT" "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }
# Assertions keep pipefail, so a broken producer cannot be masked by a
# succeeding consumer. Use `grep PATTERN >/dev/null` rather than `grep -q` in a
# pipeline: -q exits on first match, the producer takes SIGPIPE, and pipefail
# then reports failure even though the assertion held.
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

epoch() { cut -d' ' -f2 "$(pdir)/state" 2>/dev/null || echo 0; }

plant() { # plant an advisory directly in the outbox, in the current epoch
  mkdir -p "$(sdir)/outbox"
  jq -cn --arg id "$1" --arg n "$2" --argjson ep "$(epoch)" \
    '{id:$id, epoch:$ep, kind:"", note:$n, why_it_matters:"because", evidence:"", confidence:0.9}' \
    >"$(sdir)/outbox/1-$1.json"
}

plant_stale() { # a record from a previous epoch
  mkdir -p "$(sdir)/outbox"
  jq -cn --arg id "$1" --arg n "$2" --argjson ep "$(( $(epoch) - 1 ))" \
    '{id:$id, epoch:$ep, kind:"", note:$n, why_it_matters:"because", evidence:"", confidence:0.9}' \
    >"$(sdir)/outbox/0-$1.json"
}

# A worker exits immediately if another cycle holds cycle.lock. Earlier sections
# spawn workers, so a later direct invocation must wait for the lock to clear or
# it silently does nothing and fails a whole cluster of unrelated assertions.
wait_idle() {
  local i
  for i in $(seq 1 200); do
    ( exec 5>"$(sdir)/cycle.lock" 2>/dev/null; flock -n 5 ) 2>/dev/null && return 0
    sleep 0.05
  done
  echo "        (warning: cycle.lock still held after 10s)" >&2
  return 1
}

echo
echo "opt-in and controls"

check "default-off: hooks emit nothing before 'advisor on'" \
  '[ -z "$(fire PreToolUse)" ]' "a hook produced output while disabled"

check "default-off: no state directory is created while disabled" \
  '[ ! -d "$(sdir)" ]' "state created without opt-in"

"$ADV" on "$WORK" >/dev/null
check "on: state records enabled" '[ "$(cut -d" " -f1 "$(pdir)/state")" = "1" ]'

fire UserPromptSubmit >/dev/null
check "on: session state is initialised by the first hook" '[ -d "$(sdir)/outbox" ]'

# The hook payload is the normal source of session ids, and an id becomes a path
# segment. A traversal must create nothing and change nothing.
jq -cn --arg c "$WORK" '{cwd:$c, session_id:"../../escaped", transcript_path:""}' \
  | "$ADV" hook UserPromptSubmit >/dev/null 2>&1
HOOKRC=$?
check "a traversing session_id is refused by the hook" '[ "$HOOKRC" -eq 0 ]' "rc=$HOOKRC"
ESC="$(find "$ADVISOR_STATE_ROOT" -maxdepth 4 -name escaped 2>/dev/null)"
check "and it creates no state outside the sessions root" '[ -z "$ESC" ]' "$ESC"
check "and does not become the recorded current session" \
  '! grep >/dev/null escaped "$(pdir)/current-session" 2>/dev/null'
# `worker` is a public entrypoint too, and takes the id as an argument.
"$ADV" worker "$WORK" "../../escaped-worker" "" >/dev/null 2>&1
WRC=$?
check "the worker entrypoint refuses a traversing session id" '[ "$WRC" -ne 0 ]' "rc=$WRC"
ESCW="$(find "$ADVISOR_STATE_ROOT" -maxdepth 4 -name "escaped-worker" 2>/dev/null)"
check "and creates nothing outside the sessions root" '[ -z "$ESCW" ]' "$ESCW"

echo
echo "delivery"

plant id-aaa "first advisory"
out="$(fire PreToolUse)"
check "drain: pending advisory is emitted as additionalContext" \
  '[ -n "$out" ] && printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext" >/dev/null'

check "drain: emitted block carries the untrusted-provenance banner" \
  'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep >/dev/null "UNTRUSTED ADVISORY"'

check "drain: emitted block carries the sentinel for self-filtering" \
  'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep >/dev/null "⟦kibitz⟧"'

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

# Delivery is committed by an atomic per-id marker, not by reading the ledger and
# then appending to it. Those two steps are not atomic, and the lease makes the
# gap reachable: a consumer paused after claiming loses the record to a reclaim,
# the second consumer delivers, and the first resumes and delivers it again.
plant id-marker "must not be delivered twice"
out="$(fire PreToolUse)"
check "delivery creates a per-id marker, not just a ledger line" \
  '[ -n "$(find "$(sdir)/delivered" -type f 2>/dev/null)" ]' "$(ls "$(sdir)/delivered" 2>/dev/null)"
# Remove the ledger text but keep the marker: a resumed consumer with a stale
# view must still be refused, which a ledger-text check alone would not do.
: >"$(sdir)/ledger"
plant id-marker "must not be delivered twice"
check "the marker alone prevents a second delivery" '[ -z "$(fire PreToolUse)" ]'

# Upgrade path: the previous version recorded deliveries in the ledger only.
# Both consumers must honour that, or the first drain after an update re-emits.
rm -rf "$(sdir)/delivered"
printf 'legacy-delivered\n' >"$(sdir)/ledger"
plant legacy-delivered "delivered by the previous version"
check "a ledger-only delivery is honoured after upgrading" \
  '[ -z "$(fire PreToolUse)" ]' "re-emitted an advisory the old version delivered"

# Same upgraded state, now with one new delivery: the count is the union of both
# records. Preferring markers when any exist hides every pre-upgrade delivery,
# and makes the first new one *reduce* the reported total from 1 to 1.
plant id-union "delivered after the upgrade"
fire PreToolUse >/dev/null
check "the claimed count sums markers and legacy ledger lines" \
  '[ "$("$ADV" status "$WORK" | sed -n "s/.*claimed *: \([0-9]*\).*/\1/p")" = 2 ]' \
  "$("$ADV" status "$WORK" | grep claimed)"

# The label must not promise more than the records establish: a marker is
# written before the final off/epoch check, so `off` in that window leaves a
# counted advisory that was never shown.
check "status calls the count a claim on delivery, not an emission" \
  '"$ADV" status "$WORK" | grep -E "claimed *: [0-9]+ advisories committed for delivery" >/dev/null &&
   ! "$ADV" status "$WORK" | grep -E "emitted|shown|displayed|sent|received" >/dev/null' \
  "$("$ADV" status "$WORK")"

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
  'find "$(sdir)/events" -name "*.json" | xargs -r cat | grep >/dev/null "\"Edit\""'

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
# Assert the spawn DECISION, not a racing read of process state: maybe_spawn
# rewrites last-cycle exactly when it decides to run one.
BEFORE=$(cat "$(sdir)/last-cycle")
PATH="$NOSPAWN:$PATH" toolhook PostToolUse Edit >/dev/null
check "ordinary activity is debounced, no cycle spawned" \
  '[ "$(cat "$(sdir)/last-cycle")" = "$BEFORE" ]' "a cycle was started inside the debounce window"
sleep 1
PATH="$NOSPAWN:$PATH" toolhook PostToolUseFailure Bash "boom" >/dev/null
check "a failed tool call bypasses the debounce and spawns immediately" \
  '[ "$(cat "$(sdir)/last-cycle")" != "$BEFORE" ]' "a failure did not trigger a cycle"
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
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
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
wait_idle
PATH="$CAPBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "the worker feeds tap events into the prompt" \
  'grep -q "Tool calls since you last looked" "$PROMPTCAP" && grep -q "Edit" "$PROMPTCAP"'
check "consumed events are cleared, not replayed forever" '[ "$(evcount)" -eq 0 ]'
check "an empty advisory list publishes nothing" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'

# Advisory text is model- and repository-derived, and lands inside a block
# labelled untrusted. A raw newline in a field lets one advisory forge what
# looks like a second, independently-attested one.
"$ADV" on "$WORK" >/dev/null
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
jq -cn --argjson ep "$(epoch)" \
  '{id:"forge-1", epoch:$ep, kind:"a\nb", note:"real\n- forged advisory",
    why_it_matters:"w\nx", evidence:"e\nf", confidence:0.5}' \
  >"$(sdir)/outbox/1-forge.json"
out="$(fire PreToolUse | jq -r '.hookSpecificOutput.additionalContext')"
check "a newline in an advisory cannot forge a second bullet" \
  '[ "$(printf "%s" "$out" | grep -c "^- ")" = "1" ]' "$out"
check "the forged text is still shown, flattened onto its own line" \
  'printf "%s" "$out" | grep -q -- "- forged advisory"'

# A hook must exit 0 even when the host cannot spawn the worker at all.
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/last-cycle"
# Hide setsid while keeping the interpreter reachable: emptying PATH entirely
# only proves the shebang cannot resolve, which is a different failure.
RUNTIME_DIR="$(dirname "$(command -v bun 2>/dev/null || command -v bash)")"
hookjson | PATH="$RUNTIME_DIR" "$ADV" hook Stop >/dev/null 2>&1
SPAWNRC=$?   # capture immediately: inside check's eval $? is the previous command
check "a hook exits 0 when the worker cannot be spawned" '[ "$SPAWNRC" -eq 0 ]' "rc=$SPAWNRC"

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
check "off: state records disabled" '[ "$(cut -d" " -f1 "$(pdir)/state")" = "0" ]'
check "off: pending advisories are cleared, not left to leak later" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'
check "no-advice-after-off: hooks emit nothing" '[ -z "$(fire PreToolUse)" ]'

# A worker stalled inside Codex, i.e. before its publication phase.
STALLBIN="$WORK/stallbin"; mkdir -p "$STALLBIN"
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$STALLBIN/codex"; chmod +x "$STALLBIN/codex"

"$ADV" on "$WORK" >/dev/null
PATH="$STALLBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1 &
WPID=$!
# Wait for the worker to be reapable rather than guessing at a sleep: it writes
# its pidfile only after taking the cycle lock, and under load that can take
# longer than any fixed delay. `off` cannot reap what has not identified itself.
for _ in $(seq 1 100); do [ -s "$(sdir)/worker.pid" ] && break; sleep 0.05; done
check "the worker identified itself before off" '[ -s "$(sdir)/worker.pid" ]'
"$ADV" off "$WORK" >/dev/null
for _ in $(seq 1 60); do kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
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
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
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
"$ADV" on "$WORK" >/dev/null
check "nothing the stalled worker published survives into the next epoch" \
  '[ -z "$(fire PreToolUse)" ]' "a pre-off advisory was delivered after re-enabling"

# SessionEnd must reap the whole cycle. The worker waits synchronously on
# `timeout codex`, so killing only the worker leaves Codex running.
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/worker.pid"
PATH="$STALLBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1 &
EPID=$!
for _ in $(seq 1 100); do [ -s "$(sdir)/worker.pid" ] && break; sleep 0.05; done
WPID_R="$(cut -d' ' -f1 "$(sdir)/worker.pid")"
# The GRANDchild is the point: worker -> timeout -> codex. Asserting on the
# direct child only proves the wrapper died, which can happen while codex lives.
for _ in $(seq 1 100); do
  KID="$(pgrep -P "$WPID_R" 2>/dev/null | head -1)"
  [ -n "$KID" ] && GKID="$(pgrep -P "$KID" 2>/dev/null | head -1)" || GKID=""
  [ -n "$GKID" ] && break
  sleep 0.05
done
check "the cycle has a grandchild (codex under timeout) to reap" '[ -n "$GKID" ]' \
  "child=$KID grandchild=$GKID"
fire SessionEnd >/dev/null
for _ in $(seq 1 60); do kill -0 "$GKID" 2>/dev/null || break; sleep 0.05; done
check "SessionEnd reaps the codex grandchild, not just the wrapper" \
  '! kill -0 "$GKID" 2>/dev/null' "grandchild $GKID survived SessionEnd"
wait "$EPID" 2>/dev/null

# The detached path, which is the one production uses: a cycle started through
# the Stop hook runs under setsid, so killTree takes its process-group branch.
# The direct-invocation test above only ever exercises the fallback.
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/worker.pid" "$(sdir)/last-cycle"
( cd "$WORK" && PATH="$STALLBIN:$PATH" bash -c 'jq -cn --arg c "$1" --arg s "$2" \
    "{cwd:\$c, session_id:\$s, transcript_path:\"\"}" | "$3" hook Stop' _ "$WORK" "$SID" "$ADV" ) >/dev/null 2>&1
for _ in $(seq 1 120); do [ -s "$(sdir)/worker.pid" ] && break; sleep 0.05; done
SPID="$(cut -d' ' -f1 "$(sdir)/worker.pid" 2>/dev/null)"
check "the Stop hook started a detached cycle" '[ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null' \
  "pid=$SPID"
SGRP="$(awk '{print $5}' /proc/$SPID/stat 2>/dev/null)"
check "the detached cycle is in its own process group" \
  '[ -n "$SGRP" ] && [ "$SGRP" != "$$" ]' "pgid=$SGRP shell=$$"
fire SessionEnd >/dev/null
for _ in $(seq 1 80); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
check "SessionEnd ends a detached cycle through its group" \
  '! kill -0 "$SPID" 2>/dev/null' "pid $SPID survived"

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
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
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

check "no-advice-after-off holds when off races publication" \
  '[ -z "$(fire PreToolUse)" ]' "a record published during off was delivered"
"$ADV" on "$WORK" >/dev/null
check "and it stays undelivered after re-enabling" \
  '[ -z "$(fire PreToolUse)" ]' "a pre-off record was resurrected by re-enabling"

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
"$ADV" off "$WORK" >/dev/null    # lands while the drain is in flight
wait "$DPID" 2>/dev/null
check "a drain already past the outer check emits nothing once off lands" \
  '[ ! -s "$RACEOUT" ]' "advice escaped after the flag was cleared: $(cat "$RACEOUT" 2>/dev/null)"
# `off` clears the queue as housekeeping, so the record is legitimately gone.
# What matters is that re-enabling cannot resurrect it.
"$ADV" on "$WORK" >/dev/null
check "and re-enabling does not resurrect it" \
  '[ -z "$(fire PreToolUse)" ]' "a pre-off advisory was delivered after re-enabling"
"$ADV" off "$WORK" >/dev/null; "$ADV" on "$WORK" >/dev/null

# The reason `status` says "claimed" and not "emitted", made causal rather than
# asserted: land `off` AFTER the claim is committed and before the final
# authorization. Nothing is shown, yet the marker exists and is counted. A test
# that only pins the wording would stay green if this behaviour changed.
BEFORE="$("$ADV" status "$WORK" | sed -n 's/.*claimed *: \([0-9]*\).*/\1/p')"
touch "$WORK/claimmark"          # reference for "a marker newer than this"
plant id-claimrace "claimed, then off before it is shown"
CLAIMOUT="$WORK/claimrace.out"
( hookjson | ADVISOR_TEST_CLAIM_DELAY=2 "$ADV" hook PreToolUse >"$CLAIMOUT" 2>/dev/null ) &
CPID=$!
# Wait for the claim itself, not for a guessed interval: a sleep races the hook
# on a loaded host, and this test is about a specific ordering, so it must not
# depend on timing luck.
CLAIMSEEN=no
for _ in $(seq 1 50); do
  if [ -n "$(find "$(sdir)/delivered" -type f -newer "$WORK/claimmark" 2>/dev/null)" ]; then
    CLAIMSEEN=yes; break
  fi
  sleep 0.02
done
# Report a failed handshake as itself. Falling through silently would run `off`
# after the delay had already elapsed, and the ordering test would then report a
# behaviour regression that never happened.
check "the claim was observed before off was sent" '[ "$CLAIMSEEN" = yes ]' \
  "no new marker within 1s; the test never reached the window it is about"
"$ADV" off "$WORK" >/dev/null    # lands after the claim, before the emit
wait "$CPID" 2>/dev/null
check "off after the claim shows nothing" \
  '[ ! -s "$CLAIMOUT" ]' "advice escaped after off: $(cat "$CLAIMOUT" 2>/dev/null)"
"$ADV" on "$WORK" >/dev/null
check "but the claim is still counted, which is why it is not called emitted" \
  '[ "$("$ADV" status "$WORK" | sed -n "s/.*claimed *: \([0-9]*\).*/\1/p")" -eq $((BEFORE + 1)) ]' \
  "claimed went from $BEFORE to $("$ADV" status "$WORK" | sed -n 's/.*claimed *: \([0-9]*\).*/\1/p')"
"$ADV" off "$WORK" >/dev/null; "$ADV" on "$WORK" >/dev/null

# Delivery is gated on the epoch, not on a lock, so nothing can wedge the hot
# path: a stale record is dropped and a current one goes out in the same call.
plant_stale id-stale "written before the operator opted out"
plant id-fresh "written after"
out="$(fire PreToolUse)"
check "a record from an older epoch is never delivered" \
  '! printf "%s" "$out" | grep >/dev/null "before the operator opted out"'
check "a current record in the same drain is still delivered" \
  'printf "%s" "$out" | grep >/dev/null "written after"'
check "the stale record is not left lying around" \
  '[ -z "$(find "$(sdir)/outbox" -name "0-id-stale.json" 2>/dev/null)" ]'

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
wait_idle
PATH="$NOOPBIN:$PATH" ADVISOR_TRANSCRIPT_LINES=400 "$ADV" worker "$WORK" "$SID" "$BIGT" >/dev/null 2>&1
t1=$(date +%s%N)
check "a ${BYTES}-byte transcript is processed in bounded time ($(( (t1-t0)/1000000 ))ms)" \
  '[ "$(( (t1-t0)/1000000 ))" -lt 4000 ]'
# Behavioural, not a grep for a shell idiom: build a transcript whose early
# lines carry one marker and late lines another, cap the window, and require
# only the late marker to reach the prompt.
BOUNDED="$WORK/bounded.jsonl"; : >"$BOUNDED"
for i in $(seq 1 50); do
  jq -cn '{isSidechain:false, message:{role:"user", content:[{type:"text", text:"OLDMARKER"}]}}' >>"$BOUNDED"
done
for i in $(seq 1 5); do
  jq -cn '{isSidechain:false, message:{role:"user", content:[{type:"text", text:"NEWMARKER"}]}}' >>"$BOUNDED"
done
: >"$PROMPTCAP"
wait_idle
PATH="$CAPBIN:$PATH" ADVISOR_TRANSCRIPT_LINES=5 "$ADV" worker "$WORK" "$SID" "$BOUNDED" >/dev/null 2>&1
check "the transcript window is bounded by ADVISOR_TRANSCRIPT_LINES" \
  'grep -q NEWMARKER "$PROMPTCAP" && ! grep -q OLDMARKER "$PROMPTCAP"' \
  "$(grep -c MARKER "$PROMPTCAP" 2>/dev/null) marker lines reached the prompt"

echo
echo "deduplication"

"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
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
wait_idle
PATH="$UNIBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
n="$(find "$(sdir)/outbox" -name '*.json' 2>/dev/null | wc -l)"
check "two distinct non-Latin advisories are not collapsed into one" \
  '[ "$n" -eq 2 ]' "published $n of 2 — fingerprint is lossy for non-ASCII"

# And identical notes still deduplicate.
rm -f "$(sdir)/outbox"/*.json
wait_idle
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
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"; date +%s >"$(sdir)/last-cycle"
: >"$PROMPTCAP"
wait_idle
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
"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"; date +%s >"$(sdir)/last-cycle"
: >"$PROMPTCAP"
wait_idle
PATH="$CAPBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "an event written by an in-flight tap hook after off is never used" \
  '! grep -q "Edit" "$PROMPTCAP"' "pre-off activity reached the next cycle"

echo
echo "the channel (optional transport)"

# The channel drains on a timer, so these pipelines only have to hold stdin open
# for several ticks. The two numbers are tuned together: at the 50ms floor the
# server accepts, 0.6s is a dozen ticks -- the same margin the old 200ms/2s pair
# gave, in under a third of the wall clock. This section was half the suite's
# 52-second runtime, and all of it was waiting.
CHAN_POLL=50
CHAN_HOLD=0.6

# No `head` in the pipeline: it SIGPIPEs the server and pipefail then reports
# failure even when the assertion holds.
rpc() { printf '%s\n' "$1" | timeout 5 "$ADV" channel 2>/dev/null | sed -n 1p; }
# An override only fills a gap: with a real Claude ancestry the registry wins, by
# design. These runs therefore use a HOME with no session registry, which is the
# documented situation for KIBITZ_SESSION.
NOREG="$WORK/noreg"; mkdir -p "$NOREG"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
check "declares the claude/channel capability" \
  '[ "$(rpc "$INIT" | jq -c ".result.capabilities.experimental")" = "{\"claude/channel\":{}}" ]' \
  "$(rpc "$INIT")"
check "answers tools/list rather than erroring (one-way channel)" \
  '[ "$(printf "%s\n%s\n" "$INIT" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}" \
      | timeout 5 "$ADV" channel 2>/dev/null | sed -n 2p | jq -c ".result.tools")" = "[]" ]'
check "tells Claude the events are untrusted and one-way" \
  'rpc "$INIT" | jq -r ".result.instructions" | grep >/dev/null "untrusted"'
# The plugin must NOT auto-start a channel process. A skills-directory plugin is
# loaded for MCP but never as a channel, so such a process initializes, wins the
# atomic claim, writes the ledger -- and then emits a channel notification into a
# client that is not a channel and drops it. The advisory is committed as
# delivered and the hook drain will not retry it: silent loss. The named user
# registration is the only supported channel, and it must be the only consumer.
check "ships no auto-start MCP server that would become a second channel consumer" \
  '[ ! -e "$PLUG/.mcp.json" ]'

# It must be a second consumer of the SAME queue and ledger, never a duplicate
# path: whichever of the two runs delivers, and neither repeats the other.
"$ADV" on "$WORK" >/dev/null
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-1 "advice for the channel"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$NOREG" KIBITZ_SESSION="$SID" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chan.out" 2>/dev/null
check "the channel emits a channel notification for a pending advisory" \
  'grep >/dev/null "notifications/claude/channel" "$WORK/chan.out"' "$(cat "$WORK/chan.out")"
check "the notification carries the untrusted-provenance banner" \
  'grep >/dev/null "UNTRUSTED ADVISORY" "$WORK/chan.out"'
check "the channel clears the advisory from the outbox" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'
check "and records it in the same ledger the hook drain uses" \
  'grep >/dev/null -x "chan-1" "$(sdir)/ledger"'
check "so the hook drain will not deliver it a second time" \
  '[ -z "$(fire PreToolUse)" ]'

# Binding is established, never guessed. With no ancestry to resolve and no
# explicit binding, the channel declines rather than push into a session it
# cannot identify -- pushing one session's advisory into another is a
# wrong-recipient failure, not merely a late one. An mtime "recently active"
# heuristic was tried first and is not liveness: a live but idle session ages
# out and the channel then follows the project-global marker to a newer session.
"$ADV" on "$WORK" >/dev/null
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-amb "must not cross sessions"
EMPTYHOME="$WORK/nohome"; mkdir -p "$EMPTYHOME"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chanamb.out" 2>"$WORK/chanamb.err"
check "an unbindable channel refuses to push" \
  '! grep >/dev/null "must not cross sessions" "$WORK/chanamb.out"' "$(cat "$WORK/chanamb.out")"
check "and says why, once" \
  'grep >/dev/null "could not establish which Claude session" "$WORK/chanamb.err"' \
  "$(cat "$WORK/chanamb.err")"
check "the advisory stays queued for the hook drain instead" \
  '[ -n "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]'
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_SESSION="$SID" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL \
      timeout 5 "$ADV" channel ) >"$WORK/chanbound.out" 2>/dev/null
check "KIBITZ_SESSION binds it explicitly and delivery resumes" \
  'grep >/dev/null "must not cross sessions" "$WORK/chanbound.out"' "$(cat "$WORK/chanbound.out")"
# And the registry path: a session record naming this pid's ancestor binds it.
mkdir -p "$EMPTYHOME/.claude/sessions"
PROCSTART="$(awk '{print $22}' /proc/$$/stat)"
jq -n --arg s "$SID" --argjson p "$$" --arg st "$PROCSTART" \
  '{sessionId:$s, pid:$p, procStart:$st}' >"$EMPTYHOME/.claude/sessions/$$.json"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-reg "bound through the registry"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chanreg.out" 2>/dev/null
check "Claude's session registry binds the channel without configuration" \
  'grep >/dev/null "bound through the registry" "$WORK/chanreg.out"' "$(cat "$WORK/chanreg.out")"

# The override becomes a path segment, so traversal must be refused outright.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-trav "must not escape the session subtree"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_SESSION="../../elsewhere" \
      KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chantrav.out" 2>"$WORK/chantrav.err"
check "a traversal in KIBITZ_SESSION is refused" \
  'grep >/dev/null "not a valid session id" "$WORK/chantrav.err"' "$(cat "$WORK/chantrav.err")"
# The documented consequence: an invalid override is ignored and binding falls
# back to ancestry, so delivery continues for the CORRECT session. Asserted so
# the fallback is a decision rather than an accident.
check "an ignored override falls back to the ancestry binding" \
  'grep >/dev/null "must not escape the session subtree" "$WORK/chantrav.out"' \
  "$(cat "$WORK/chantrav.out")"
ESCAPED="$(find "$ADVISOR_STATE_ROOT" -maxdepth 4 -name elsewhere 2>/dev/null)"
check "and nothing was created outside the project subtree" '[ -z "$ESCAPED" ]' "$ESCAPED"

# The registry is the automatic path, so it gets the same validation.
jq -n --argjson p "$$" --arg st "$PROCSTART" \
  '{sessionId:"../../elsewhere", pid:$p, procStart:$st}' >"$EMPTYHOME/.claude/sessions/$$.json"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-badreg "must not bind through a traversing record"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chanbadreg.out" 2>/dev/null
check "a traversing sessionId in the registry is refused too" \
  '! grep >/dev/null "must not bind through a traversing record" "$WORK/chanbadreg.out"' \
  "$(cat "$WORK/chanbadreg.out")"
jq -n --arg s "$SID" --argjson p "$$" --arg st "$PROCSTART" \
  '{sessionId:$s, pid:$p, procStart:$st}' >"$EMPTYHOME/.claude/sessions/$$.json"

# An override may fill a gap, never contradict the evidence. A stale or inherited
# value naming another session would drain that session's queue into this one.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-conflict "belongs to the bound session"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_SESSION="a-different-session" \
      KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chanconf.out" 2>"$WORK/chanconf.err"
check "an override that contradicts the registry is ignored" \
  'grep >/dev/null "ignoring the override" "$WORK/chanconf.err"' "$(cat "$WORK/chanconf.err")"
check "and the registry binding is used instead" \
  'grep >/dev/null "belongs to the bound session" "$WORK/chanconf.out"' "$(cat "$WORK/chanconf.out")"

# A stale record whose pid the kernel reused must not bind: same wrong-recipient
# failure, reached from the other direction.
jq -n --arg s "$SID" --argjson p "$$" --arg st "999999999" \
  '{sessionId:$s, pid:$p, procStart:$st}' >"$EMPTYHOME/.claude/sessions/$$.json"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-stale "must not bind through a stale record"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) \
  >"$WORK/chanstale.out" 2>/dev/null
check "a stale registry record does not bind the channel" \
  '! grep >/dev/null "must not bind through a stale record" "$WORK/chanstale.out"' \
  "$(cat "$WORK/chanstale.out")"

# CLAUDE_CONFIG_DIR relocates the registry, and the channel must follow it.
RELOC="$WORK/reloc"; mkdir -p "$RELOC/sessions"
jq -n --arg s "$SID" --argjson p "$$" --arg st "$PROCSTART" \
  '{sessionId:$s, pid:$p, procStart:$st}' >"$RELOC/sessions/$$.json"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-reloc "bound through a relocated config"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; sleep $CHAN_HOLD ) \
  | ( cd "$WORK" && HOME="$EMPTYHOME" CLAUDE_CONFIG_DIR="$RELOC" \
      KIBITZ_CHANNEL_POLL_MS=$CHAN_POLL timeout 5 "$ADV" channel ) >"$WORK/chanreloc.out" 2>/dev/null
check "CLAUDE_CONFIG_DIR relocates the registry the channel reads" \
  'grep >/dev/null "bound through a relocated config" "$WORK/chanreloc.out"' \
  "$(cat "$WORK/chanreloc.out")"

# `off` landing mid-drain must stop the channel too, not only the hook.
# The only test here that wants a SLOW poll: it has to land `off` inside the
# window between queueing an advisory and the tick that would drain it, so the
# tick interval is the window and it must outlast an `off` process starting up.
# Speeding this one up is what makes it stop testing anything.
"$ADV" on "$WORK" >/dev/null
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant chan-off "must not be pushed after off"
( printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.4; ( cd "$WORK" && "$ADV" off "$WORK" >/dev/null ); sleep 1.2 ) \
  | ( cd "$WORK" && HOME="$NOREG" KIBITZ_SESSION="$SID" KIBITZ_CHANNEL_POLL_MS=1000 timeout 6 "$ADV" channel ) \
  >"$WORK/chanoff.out" 2>/dev/null
check "off stops the channel pushing, as it stops the hook drain" \
  '! grep >/dev/null "must not be pushed after off" "$WORK/chanoff.out"' \
  "$(cat "$WORK/chanoff.out")"
"$ADV" on "$WORK" >/dev/null

echo
echo "the plugin package"

check "ships a plugin manifest" '[ -f "$PLUG/.claude-plugin/plugin.json" ]'
check "the manifest is valid JSON with a name" \
  '[ "$(jq -r .name "$PLUG/.claude-plugin/plugin.json")" = "kibitz" ]'
check "ships plugin hooks at the path Claude Code reads" '[ -f "$PLUG/hooks/hooks.json" ]'
check "plugin hooks cover every event the tap needs" \
  'for e in PreToolUse UserPromptSubmit PostToolUse PostToolUseFailure Stop SubagentStop SessionEnd; do
     jq -e --arg e "$e" ".hooks[\$e]" "$PLUG/hooks/hooks.json" >/dev/null || exit 1; done'
# The whole point of the plugin route: no absolute path baked in anywhere.
# Count outside the assertion -- check's eval would expand ${CLAUDE_PLUGIN_ROOT}
# itself, and under `set -u` that aborts the test rather than failing it.
HOOKTOTAL=$(jq -r '[.hooks[][].hooks[].command] | length' "$PLUG/hooks/hooks.json")
# startswith, not contains: `echo CLAUDE_PLUGIN_ROOT; /baked/path/kibitz ...`
# would satisfy a substring check while reintroducing an absolute path.
HOOKPREFIX='"${CLAUDE_PLUGIN_ROOT}"/bin/kibitzer hook '
HOOKROOTED=$(jq -r --arg p "$HOOKPREFIX" '[.hooks[][].hooks[].command]
                    | map(select(startswith($p))) | length' "$PLUG/hooks/hooks.json")
check "every plugin hook resolves through CLAUDE_PLUGIN_ROOT" \
  '[ "$HOOKROOTED" -eq "$HOOKTOTAL" ] && [ "$HOOKTOTAL" -eq 7 ]' \
  "$HOOKROOTED of $HOOKTOTAL"
# Seven rooted commands is not enough: a swapped suffix (Stop invoking
# `hook PreToolUse`) satisfies every check above and silently misroutes the
# lifecycle. Pin each event to its own handler, in both maintained configs.
mismatch=$(jq -r '[.hooks | to_entries[] | .key as $e | .value[].hooks[]
                   | select((.command | endswith(" hook " + $e)) | not)
                   | "\($e): \(.command)"] | .[]' "$PLUG/hooks/hooks.json")
check "each plugin hook invokes the handler for its own event" \
  '[ -z "$mismatch" ]' "$mismatch"
tmismatch=$(jq -r '[.hooks | to_entries[] | .key as $e | .value[].hooks[]
                    | select((.command | endswith(" hook " + $e)) | not)
                    | "\($e): \(.command)"] | .[]' "$PLUG/install/hooks.json")
check "each settings.json template hook does too" \
  '[ -z "$tmismatch" ]' "$tmismatch"
check "both configs cover the same events" \
  '[ "$(jq -S -r ".hooks|keys|join(\",\")" "$PLUG/hooks/hooks.json")" = \
     "$(jq -S -r ".hooks|keys|join(\",\")" "$PLUG/install/hooks.json")" ]' \
  "plugin: $(jq -r '.hooks|keys|join(",")' "$PLUG/hooks/hooks.json") / template: $(jq -r '.hooks|keys|join(",")' "$PLUG/install/hooks.json")"

check "no absolute path leaks into the plugin hooks" \
  '! grep -q "/home/" "$PLUG/hooks/hooks.json"'
check "the executable the hooks name is present and runnable" '[ -x "$PLUG/bin/kibitzer" ]'
check "the legacy settings.json template is out of the plugin hook path" \
  '[ -f "$PLUG/install/hooks.json" ] && [ ! -f "$PLUG/hooks.json" ]'

# A user hook that merely mentions our command must not be treated as ours.
# A checkout whose path contains spaces must produce a hook that can actually
# run, and that we can still recognise as ours later. Quoting the executable is
# what makes it runnable; the ownership regex has to accept that quoted form or
# uninstall silently leaves it behind.
SPACED="$WORK/dir with space"; mkdir -p "$SPACED"
cp -r "$PLUG" "$SPACED/kibitz"
SPROJ="$WORK/spaceproj"; mkdir -p "$SPROJ/.claude"
( cd "$SPROJ" && "$SPACED/kibitz/bin/kibitzer" install project ) >/dev/null 2>&1
scmd=$(jq -r '.hooks.Stop[]?.hooks[]?.command' "$SPROJ/.claude/settings.json" 2>/dev/null)
check "a checkout path with spaces yields a quoted, runnable command" \
  '[ "${scmd:0:1}" = "\"" ]' "$scmd"
check "and the quoted executable actually exists" \
  'eval "[ -x ${scmd% hook Stop} ]"' "$scmd"
( cd "$SPROJ" && "$SPACED/kibitz/bin/kibitzer" uninstall project ) >/dev/null 2>&1
check "uninstall removes the quoted spaced-path hook" \
  '[ -z "$(jq -r ".hooks.Stop[]?.hooks[]?.command // empty" "$SPROJ/.claude/settings.json" 2>/dev/null)" ]' \
  "$(jq -c '.hooks' "$SPROJ/.claude/settings.json" 2>/dev/null)"

MIXDIR="$WORK/anchor"; mkdir -p "$MIXDIR/.claude"

# An absolute-prefixed wrapper is somebody else's command and must survive.
# An earlier revision claimed it, to reach legacy spaced hooks; provenance
# matching reaches those instead, so the promise no longer has an exception.
# The quoted form is different and is asserted separately below.
for wrapper in "/usr/bin/logger /x/bin/kibitzer hook Stop" \
               "/usr/bin/env X=1 /x/bin/kibitzer hook Stop"; do
  for op in install uninstall; do
    jq -n --arg c "$wrapper" '{hooks:{Stop:[{hooks:[{type:"command",command:$c}]}]}}' \
      >"$MIXDIR/.claude/settings.json"
    ( cd "$MIXDIR" && "$PLUG/bin/kibitzer" "$op" project ) >/dev/null 2>&1
    kept=$(jq -r --arg c "$wrapper" '[.hooks.Stop[]?.hooks[]?.command]
                                     | map(select(. == $c)) | length' \
           "$MIXDIR/.claude/settings.json" 2>/dev/null)
    check "$op keeps an absolute-prefixed wrapper" '[ "$kept" = "1" ]' "$wrapper"
  done
done

# Quoted, it is one executable path ending in /bin/kibitzer -- not a wrapper --
# so claiming it is correct rather than a cost.
jq -n '{hooks:{Stop:[{hooks:[{type:"command",
  command:"\"/usr/bin/logger /x/bin/kibitzer\" hook Stop"}]}]}}' >"$MIXDIR/.claude/settings.json"
( cd "$MIXDIR" && "$PLUG/bin/kibitzer" uninstall project ) >/dev/null 2>&1
check "a quoted path ending in /bin/kibitzer is claimed" \
  '[ -z "$(jq -r ".hooks.Stop[]?.hooks[]?.command // empty" "$MIXDIR/.claude/settings.json" 2>/dev/null)" ]' \
  "$(jq -c '.hooks' "$MIXDIR/.claude/settings.json" 2>/dev/null)"

echo
echo "the executable name"

# /usr/bin/kibitz is expect(1)'s utility on most Debian/Ubuntu systems. A plugin
# bin/ named kibitz is shadowed by it, and `kibitz on` silently runs the wrong
# program -- which is exactly what happened on a real install.
check "the shipped executable is not named kibitz" '[ ! -e "$PLUG/bin/kibitz" ]' \
  "$(ls "$PLUG/bin")"
check "it is named kibitzer and is runnable" '[ -x "$PLUG/bin/kibitzer" ]'

# `link` is the escape hatch when the plugin bin/ is shadowed, so it has to
# create the command it says it creates. A blind rename previously made it write
# $dir/kibitzerer while reporting $dir/kibitzer, and nothing noticed.
LINKD="$WORK/linkbin"
( "$PLUG/bin/kibitzer" link "$LINKD" ) >"$WORK/link.out" 2>&1
check "link creates exactly the command it reports" \
  '[ -L "$LINKD/kibitzer" ] && [ "$(find "$LINKD" -mindepth 1 | wc -l)" = "1" ]' \
  "$(ls -a "$LINKD" 2>/dev/null); $(cat "$WORK/link.out")"
# Help text is the discovery path for the escape hatch: if it names the
# colliding command, a user following it lands on /usr/bin/kibitz.
check "help names the command link actually creates" \
  '"$PLUG/bin/kibitzer" | grep >/dev/null "put a .kibitzer. command"' \
  "$("$PLUG/bin/kibitzer" | grep link)"
# Same drift, different file: the docs have named the colliding command three
# times now. Derive the subcommand list from the help output rather than
# hardcoding it -- a hardcoded list is how `statusline` was missed -- and keep
# the paths in a quoted array so a checkout under a spaced path still scans.
mapfile -t SUBCMDS < <("$PLUG/bin/kibitzer" | sed -n 's/^  kibitzer \([a-z-]*\).*/\1/p' | sort -u)
check "the help output actually lists subcommands to check" '[ "${#SUBCMDS[@]}" -ge 10 ]' \
  "${SUBCMDS[*]:-none}"
# SUBCMDS is derived from help, so a command wired into the dispatcher but never
# documented would escape the scan entirely. Compare the two lists directly.
# Real subcommands only: the help aliases are not things the docs must list.
mapfile -t DISPATCH < <({ sed -n 's/^ *case "\([a-z][a-z-]*\)":.*/\1/p' "$ADV"     # TypeScript
                          sed -n 's/^  \([a-z][a-z-]*\))  *shift; cmd_.*/\1/p' "$ADV"; } \
                        | grep -vx help | sort -u)
check "the dispatcher list parsed at all" \
  '[ "${#DISPATCH[@]}" -ge 10 ] && case " ${DISPATCH[*]} " in *" on "*) true ;; *) false ;; esac' \
  "${DISPATCH[*]:-none}"
missing=""
for c in "${DISPATCH[@]}"; do
  case " ${SUBCMDS[*]} " in *" $c "*) ;; *) missing="$missing $c" ;; esac
done
check "every dispatcher subcommand appears in the help output" '[ -z "$missing" ]' \
  "undocumented:$missing"
# SKILL.md frontmatter quotes what a USER might say ("kibitz on") as trigger
# phrases, not shell commands. Scan the body only.
SKILLBODY="$WORK/skillbody.md"
awk 'NR>1 && /^---$/{f=1;next} f' "$PLUG/SKILL.md" >"$SKILLBODY"
DOCS=("$HERE/../README.md" "$SKILLBODY")
SUBRE="$(IFS='|'; printf '%s' "${SUBCMDS[*]}")"
# grep exit 1 is "no match" (good); 2 is an error and must not read as a pass.
# No backtick requirement: the README lists commands as plain indented text, so
# a stale entry there would otherwise sail through. `kibitz ` with a trailing
# space cannot match `kibitzer on`.
staledoc="$(grep -nE "(^|[^-a-zA-Z0-9_/])kibitz ($SUBRE)([^a-zA-Z0-9-]|\$)" "${DOCS[@]}")"; grc=$?
check "the doc scan ran without error" '[ "$grc" -le 1 ]' "grep exited $grc"
check "no doc instructs a bare kibitz subcommand" '[ -z "$staledoc" ]' "$staledoc"

# A representative set of diagnostic paths, executed. Exhaustive coverage comes
# from the static scan below instead -- running every command would mean writing
# settings files, opening panes and invoking Codex.
runtimeout="$("$PLUG/bin/kibitzer" lint "$PLUG/SKILL.md" 2>&1
              "$PLUG/bin/kibitzer" quiet bogus 2>&1 || true
              "$PLUG/bin/kibitzer" status "$WORK" 2>&1 || true
              "$PLUG/bin/kibitzer" mute 2>&1 || true
              "$PLUG/bin/kibitzer" doctor 2>&1 || true
              "$PLUG/bin/kibitzer" bogus-subcommand 2>&1 || true)"
check "runtime diagnostics never print a bare kibitz command" \
  '! printf "%s" "$runtimeout" | grep -qE "(^|[^-a-zA-Z0-9_/])kibitz [a-z]"' "$runtimeout"

# Static and genuinely exhaustive: the whole source, not just echo/printf lines.
# Gating on those missed heredocs -- cmd_install's guidance block and usage() are
# both `cat <<EOF`, and a stale command in either would have passed.
SRCFILES=("$PLUG/bin/kibitzer")
for f in "$PLUG"/src/*.ts; do [ -f "$f" ] && SRCFILES+=("$f"); done
stalesrc="$(grep -nE "(^|[^-a-zA-Z0-9_/])kibitz ($SUBRE)([^a-zA-Z0-9-]|\$)" \
            "${SRCFILES[@]}" || true)"
check "no message anywhere in the source names a bare kibitz command" \
  '[ -z "$stalesrc" ]' "$stalesrc"
# Diagnostic labels only, and deliberately not the help title: usage() opens with
# `kibitz — Codex as a…`, which is the product name, not something to type. The
# command-shaped scans above cannot see a label like `kibitz  <cwd>`, because two
# spaces stop `kibitz ` from being followed by a word.
badlabel="$(grep -nE "(echo|printf|out|err|write)\(? *[\"\`']kibitz[^e]" "${SRCFILES[@]}" || true)"
check "no echo/printf diagnostic label uses the shadowed name" \
  '[ -z "$badlabel" ]' "$badlabel"

check "no help line tells the user to run a bare kibitz" \
  '! "$PLUG/bin/kibitzer" | grep -E >/dev/null "^  kibitz( |$)|\`kibitz\`"' \
  "$("$PLUG/bin/kibitzer" | grep -E "^  kibitz( |$)|.kibitz." || true)"

check "the link resolves to the real executable" \
  '[ "$(readlink -f "$LINKD/kibitzer")" = "$(readlink -f "$PLUG/bin/kibitzer")" ]'
check "link refuses to clobber a foreign command of the same name" \
  'rm -f "$LINKD/kibitzer"; printf "#!/bin/sh\necho theirs\n" >"$LINKD/kibitzer";
   chmod +x "$LINKD/kibitzer";
   ! "$PLUG/bin/kibitzer" link "$LINKD" >/dev/null 2>&1 &&
   grep >/dev/null theirs "$LINKD/kibitzer"'
# Scoped to our own path shape: the docs legitimately mention /usr/bin/kibitz
# when explaining why the executable is not called that.
check "no config or doc invokes a bin/kibitz we no longer ship" \
  '! grep -rnE "(skills/kibitz|PLUGIN_ROOT.)/bin/kibitz[^e]" \
      "$PLUG/hooks" "$PLUG/install" "$PLUG/SKILL.md" >/dev/null'

# The README shows the by-path invocation, which is the form a user copies when
# the command is shadowed -- exactly the regression this rename is about. One
# mention is intentional: the sentence telling people to delete old
# `/bin/kibitz hook` entries. Anything else is drift.
# Exclude by OCCURRENCE, not by line: a line-based `grep -v` would let a line
# that both mentions removing `/bin/kibitz hook` entries and shows
# `/bin/kibitz on` slip through whole.
stalepath="$(grep -oE 'skills/kibitz/bin/kibitz([^e]|$)[a-z]*' "$HERE/../README.md" \
             | grep -v '^skills/kibitz/bin/kibitz hook' || true)"
check "the README never shows a by-path bin/kibitz invocation" \
  '[ -z "$stalepath" ]' "$stalepath"

echo
echo "install through a symlink  (found by the advisor, on itself)"

# ADVISOR_HOME must come from the *resolved* script path. Invoked via a symlink
# with no override -- the documented entrypoint -- the sibling lib/ and
# hooks.json must still be found.
LINKROOT="$WORK/linkroot"; mkdir -p "$LINKROOT"
ln -sfn "$HERE/../skills/kibitz/bin" "$LINKROOT/bin"
( cd "$LINKROOT" && ./bin/kibitzer doctor ) >"$WORK/doctor.out" 2>&1
check "doctor finds schema and prompt through a symlinked bin/" \
  '[ -s "$WORK/doctor.out" ] && ! grep -q "MISS" "$WORK/doctor.out"' "$(cat "$WORK/doctor.out")"

INSTDIR="$WORK/instproj"; mkdir -p "$INSTDIR"
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" install project ) >"$WORK/install.out" 2>&1
check "install works through a symlink with no ADVISOR_HOME override" \
  '[ -f "$INSTDIR/.claude/settings.json" ]' "$(cat "$WORK/install.out")"
check "install registers the tap events too" \
  'jq -e ".hooks.PostToolUse and .hooks.PostToolUseFailure and .hooks.Stop" "$INSTDIR/.claude/settings.json" >/dev/null'
check "installed commands point at the real script, not the symlink dir" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep >/dev/null "skills/kibitz/bin/kibitzer"'

# Existing hooks must survive, and uninstall must put things back.
# Uninstall on a project that never installed anything is a no-op, not an error,
# and must not invent a hooks key in a file that had none.
printf '{"model":"x"}\n' >"$INSTDIR/.claude/settings.json"
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" uninstall project ) >"$WORK/un.out" 2>&1
UNRC=$?   # capture immediately: inside check's eval, $? is the previous command
check "uninstall succeeds on settings with no hooks at all" \
  '[ "$UNRC" -eq 0 ]' "rc=$UNRC $(cat "$WORK/un.out")"
check "uninstall leaves a hookless file untouched" \
  '[ "$(jq -S . "$INSTDIR/.claude/settings.json")" = "$(jq -S -n "{model:\"x\"}")" ]' \
  "$(cat "$INSTDIR/.claude/settings.json")"

printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"model":"x"}\n' \
  >"$INSTDIR/.claude/settings.json"
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" install project ) >/dev/null 2>&1
check "install preserves a pre-existing hook on the same event" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep >/dev/null "echo mine"'
check "install preserves unrelated settings" \
  '[ "$(jq -r ".model" "$INSTDIR/.claude/settings.json")" = "x" ]'
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"model":"x"}\n' \
  >"$INSTDIR/.claude/settings.json"
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" install project ) >/dev/null 2>&1
# Claude allows several commands inside one hook group. Filtering by group
# instead of by command destroys a user's command that happens to sit next to
# ours -- the previous tests only ever used separate groups, so they missed it.
cat >"$INSTDIR/.claude/settings.json" <<MIXED
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"echo theirs","timeout":2},
  {"type":"command","command":"/old/skills/kibitz/bin/kibitzer hook Stop","timeout":2}
]}]},"model":"x"}
MIXED
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" install project ) >/dev/null 2>&1
check "install keeps a user command nested alongside ours" \
  'jq -r "[.hooks.Stop[].hooks[].command] | .[]" "$INSTDIR/.claude/settings.json" | grep >/dev/null "echo theirs"' \
  "$(jq -r '[.hooks.Stop[].hooks[].command] | .[]' "$INSTDIR/.claude/settings.json" 2>/dev/null)"
check "install still drops a stale hook nested alongside it" \
  '! jq -r "[.hooks.Stop[].hooks[].command] | .[]" "$INSTDIR/.claude/settings.json" | grep >/dev/null "/old/skills"'
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" uninstall project ) >/dev/null 2>&1
check "uninstall keeps a user command nested alongside ours" \
  'jq -r "[.hooks.Stop[].hooks[].command] | .[]" "$INSTDIR/.claude/settings.json" | grep >/dev/null "echo theirs"' \
  "$(jq -r '.hooks | tostring' "$INSTDIR/.claude/settings.json" 2>/dev/null)"

printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"model":"x"}\n' \
  >"$INSTDIR/.claude/settings.json"
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" install project ) >/dev/null 2>&1
( cd "$INSTDIR" && "$LINKROOT/bin/kibitzer" uninstall project ) >/dev/null 2>&1
check "uninstall removes only our hooks" \
  'jq -r ".hooks.Stop[].hooks[].command" "$INSTDIR/.claude/settings.json" | grep >/dev/null "echo mine" &&
   ! jq -r ".hooks | tostring" "$INSTDIR/.claude/settings.json" | grep >/dev/null "advisor hook"'

echo
echo "Claude channel installation"

# Claude owns .claude.json and is its only writer. A small compatible stand-in
# makes this suite test our ownership gate and host-CLI delegation without
# needing credentials or touching a real user config.
CHROOT="$WORK/channel-install"
AGENTSKILL="$CHROOT/.agents/skills/kibitz"
CLAUDESKILL="$CHROOT/.claude/skills/kibitz"
CHCFG="$CHROOT/config"
FAKEBIN="$CHROOT/fake-bin"
mkdir -p "$AGENTSKILL" "$CHCFG" "$FAKEBIN" "$(dirname "$CLAUDESKILL")"
cp -a "$PLUG/." "$AGENTSKILL/"
ln -s ../../../.agents/skills/kibitz "$CLAUDESKILL"
cat >"$FAKEBIN/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = mcp ] || exit 64
action="${2:-}"; shift 2
[ "${1:-}" = --scope ] && shift 2
name="${1:-}"; shift
# Claude spells stdio environment variables as repeated `-e KEY=value` AFTER the
# server name -- the option is variadic, so a leading one eats the name and the
# real CLI rejects the command. Parse the shape the real one accepts, or this
# stand-in green-lights an ordering that cannot work.
envjson='{}'
while [ "${1:-}" = "-e" ]; do
  kv="${2:-}"; shift 2
  envjson="$(printf '%s' "$envjson" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k]=$v')"
done
cfg="${CLAUDE_CONFIG_DIR:?}/.claude.json"
mkdir -p "$(dirname "$cfg")"
[ -f "$cfg" ] || printf '{}\n' >"$cfg"
printf '%s %s\n' "$action" "$name" >>"${KIBITZ_FAKE_CLAUDE_LOG:?}"
# Fail the FIRST matching action only, so a restore attempt that follows can
# still succeed. A stand-in that only ever succeeds cannot reach the window
# between remove and add, which is where the destructive failure lives.
if [ -n "${KIBITZ_FAKE_CLAUDE_FAIL:-}" ] && [ "$action" = "$KIBITZ_FAKE_CLAUDE_FAIL" ] &&
   [ ! -e "$KIBITZ_FAKE_CLAUDE_LOG.failed" ]; then
  : >"$KIBITZ_FAKE_CLAUDE_LOG.failed"
  exit 1
fi
# Succeed loudly, write nothing: a zero exit is not proof the record is there.
[ "${KIBITZ_FAKE_CLAUDE_NOOP:-}" = "$action" ] && exit 0
# Succeed, but write someone else's record: the name being occupied is not proof
# either. First matching action only, as above.
if [ -n "${KIBITZ_FAKE_CLAUDE_HIJACK:-}" ] && [ "$action" = "$KIBITZ_FAKE_CLAUDE_HIJACK" ] &&
   [ ! -e "$KIBITZ_FAKE_CLAUDE_LOG.hijacked" ]; then
  : >"$KIBITZ_FAKE_CLAUDE_LOG.hijacked"
  tmp="$cfg.fake.$$"
  jq --arg n "$name" '.mcpServers //= {} | .mcpServers[$n] = {type:"stdio", command:"/bin/true", args:["serve"]}' \
    "$cfg" >"$tmp"
  mv "$tmp" "$cfg"
  exit 0
fi
case "$action" in
  add)
    [ "${1:-}" = -- ] && shift
    bin="${1:-}"; arg="${2:-}"
    tmp="$cfg.fake.$$"
    jq --arg n "$name" --arg b "$bin" --arg a "$arg" --argjson e "$envjson" \
      '.mcpServers //= {} | .mcpServers[$n] = {type:"stdio", command:$b, args:[$a], env:$e}' "$cfg" >"$tmp"
    mv "$tmp" "$cfg"
    ;;
  remove)
    tmp="$cfg.fake.$$"
    jq --arg n "$name" 'del(.mcpServers[$n])' "$cfg" >"$tmp"
    mv "$tmp" "$cfg"
    ;;
  *) exit 64 ;;
esac
FAKECLAUDE
chmod +x "$FAKEBIN/claude"
CHENV="PATH=$FAKEBIN:$PATH CLAUDE_CONFIG_DIR=$CHCFG KIBITZ_FAKE_CLAUDE_LOG=$CHROOT/claude.log"

eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >"$WORK/channel-install.out" 2>&1
check "channel install delegates registration to Claude's user writer" \
  'grep >/dev/null "add kibitz-channel" "$CHROOT/claude.log"' "$(cat "$WORK/channel-install.out")"
check "channel install honours CLAUDE_CONFIG_DIR and writes the exact stdio entry" \
  'jq -e --arg b "$AGENTSKILL/bin/kibitzer" '\'' .mcpServers["kibitz-channel"] | (.type == "stdio" and .command == $b and .args == ["channel"]) '\'' "$CHCFG/.claude.json" >/dev/null'

# The documented Claude skill path is a symlink to the agents copy. It remains
# owned across the upgrade and gets rewritten to the canonical executable.
jq -n --arg b "$CLAUDESKILL/bin/kibitzer" \
  '{mcpServers:{"kibitz-channel":{command:$b,args:["channel"]}}}' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
check "channel install recognises the npx Claude symlink as its own registration" \
  'grep >/dev/null "remove kibitz-channel" "$CHROOT/claude.log" && grep >/dev/null "add kibitz-channel" "$CHROOT/claude.log"'
check "channel install refreshes an owned symlink record to the real executable" \
  'jq -e --arg b "$AGENTSKILL/bin/kibitzer" '\''.mcpServers["kibitz-channel"].command == $b'\'' "$CHCFG/.claude.json" >/dev/null'

jq -n '{mcpServers:{"kibitz-channel":{type:"stdio",command:"/bin/true",args:["channel"]}}}' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel install refuses a foreign same-name server" '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ]'
check "foreign channel registration survives refusal unchanged" \
  'jq -e '\''.mcpServers["kibitz-channel"].command == "/bin/true"'\'' "$CHCFG/.claude.json" >/dev/null'

eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user --replace-channel" >/dev/null 2>&1
check "explicit channel replacement is delegated as remove then add" \
  '[ "$(cat "$CHROOT/claude.log")" = $'\''remove kibitz-channel\nadd kibitz-channel'\'' ]' "$(cat "$CHROOT/claude.log")"

printf '{ bad json\n' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel install refuses malformed Claude config without invoking Claude" \
  '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ]'

jq -n --arg b "$CHROOT/gone/bin/kibitzer" \
  '{mcpServers:{"kibitz-channel":{command:$b,args:["channel"]}}}' >"$CHCFG/.claude.json"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" uninstall claude-channel-user" >/dev/null 2>&1
check "channel uninstall removes a stale but recognisable kibitzer path" \
  'jq -e '\''.mcpServers["kibitz-channel"] | not'\'' "$CHCFG/.claude.json" >/dev/null'

jq -n '{mcpServers:{"kibitz-channel":{type:"stdio",command:"/bin/true",args:["channel"]}}}' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" uninstall claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel uninstall leaves a foreign registration untouched" \
  '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ] &&
   [ "$(jq -r '\''.mcpServers["kibitz-channel"].command'\'' "$CHCFG/.claude.json")" = /bin/true ]'

# The refresh is two Claude commands. If the add fails after the remove has
# already succeeded, the operator must not be left with no channel at all -- a
# transient CLI failure turning an upgrade into an outage.
printf '{}\n' >"$CHCFG/.claude.json"; : >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
rm -f "$CHROOT/claude.log.failed"; : >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_FAIL=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" \
  >"$WORK/chan-fail.out" 2>&1
CHRC=$?
check "a failed channel add puts back the registration it removed" \
  '[ "$CHRC" -ne 0 ] &&
   [ "$(jq -r '\''.mcpServers["kibitz-channel"].command'\'' "$CHCFG/.claude.json")" = "$AGENTSKILL/bin/kibitzer" ]' \
  "$(cat "$WORK/chan-fail.out")"
check "and says so rather than reporting a bare failure" \
  'grep >/dev/null "restored the previous" "$WORK/chan-fail.out"' "$(cat "$WORK/chan-fail.out")"

# An add that exits zero and registers nothing loses the same entry, and a
# restore that exits zero and writes nothing must not be reported as a restore.
printf '{}\n' >"$CHCFG/.claude.json"; : >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
: >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_NOOP=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" \
  >"$WORK/chan-noop.out" 2>&1
CHRC=$?
check "a silent no-op add is a failure, not a registration" \
  '[ "$CHRC" -ne 0 ] && ! grep >/dev/null "restored the previous" "$WORK/chan-noop.out"' \
  "$(cat "$WORK/chan-noop.out")"
check "and the operator is given the command that puts the entry back" \
  'grep >/dev/null "claude mcp add --scope user kibitz-channel -- '\''$AGENTSKILL/bin/kibitzer'\'' '\''channel'\''" \
     "$WORK/chan-noop.out"' "$(cat "$WORK/chan-noop.out")"

# That line is written to be pasted into a shell, and its words come from a
# config we do not control.
jq -n --arg b "$CHROOT/od d/bin/kibitzer" \
  '{mcpServers:{"kibitz-channel":{type:"stdio",command:$b,args:["channel"]}}}' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_NOOP=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user --replace-channel" \
  >"$WORK/chan-quote.out" 2>&1
check "a path with a space comes back quoted, not as two words" \
  'grep >/dev/null "'\''$CHROOT/od d/bin/kibitzer'\''" "$WORK/chan-quote.out"' \
  "$(cat "$WORK/chan-quote.out")"

# env is the one field beyond command and args that Claude's writer can set, so
# restoration must carry it rather than report it lost.
jq -n --arg b "$AGENTSKILL/bin/kibitzer" \
  '{mcpServers:{"kibitz-channel":{type:"stdio",command:$b,args:["channel"],env:{KIBITZ_SESSION:"s1"}}}}' \
  >"$CHCFG/.claude.json"
rm -f "$CHROOT/claude.log.failed"; : >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_FAIL=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" \
  >"$WORK/chan-env.out" 2>&1
check "a restored record keeps the env the previous one carried" \
  '[ "$(jq -r '\''.mcpServers["kibitz-channel"].env.KIBITZ_SESSION'\'' "$CHCFG/.claude.json")" = s1 ]' \
  "$(cat "$WORK/chan-env.out")"
check "and that counts as a full restore, not a partial one" \
  'grep >/dev/null "restored the previous" "$WORK/chan-env.out"' "$(cat "$WORK/chan-env.out")"

# A flag value comes back a string, so a number or a boolean cannot be restored
# as it was. Reporting that as restored would be the false all-clear again.
jq -n --arg b "$AGENTSKILL/bin/kibitzer" \
  '{mcpServers:{"kibitz-channel":{type:"stdio",command:$b,args:["channel"],env:{PORT:1}}}}' \
  >"$CHCFG/.claude.json"
rm -f "$CHROOT/claude.log.failed"; : >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_FAIL=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" \
  >"$WORK/chan-env2.out" 2>&1
check "an env value the writer cannot reproduce is reported, not called restored" \
  '! grep >/dev/null "restored the previous" "$WORK/chan-env2.out" &&
   grep >/dev/null "not in full" "$WORK/chan-env2.out"' "$(cat "$WORK/chan-env2.out")"

# The name being occupied afterwards is not the record being back either: a
# concurrent writer can take it, and "restored" must never be said on that.
printf '{}\n' >"$CHCFG/.claude.json"; : >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
rm -f "$CHROOT/claude.log.hijacked"; : >"$CHROOT/claude.log"
eval "$CHENV KIBITZ_FAKE_CLAUDE_HIJACK=add \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" \
  >"$WORK/chan-hijack.out" 2>&1
CHRC=$?
check "a name taken by another writer is never reported as restored" \
  '[ "$CHRC" -ne 0 ] && ! grep >/dev/null "restored the previous" "$WORK/chan-hijack.out"' \
  "$(cat "$WORK/chan-hijack.out")"
check "and that other record is left where it is, not overwritten" \
  '[ "$(jq -r '\''.mcpServers["kibitz-channel"].command'\'' "$CHCFG/.claude.json")" = /bin/true ]'

# Sharing our filename is not evidence of being us. A command that resolves to a
# different executable is someone else's, and these commands delete entries.
OTHERBIN="$CHROOT/other-install/bin"
mkdir -p "$OTHERBIN"; printf '#!/bin/sh\nexit 0\n' >"$OTHERBIN/kibitzer"; chmod +x "$OTHERBIN/kibitzer"
jq -n --arg b "$OTHERBIN/kibitzer" \
  '{mcpServers:{"kibitz-channel":{command:$b,args:["channel"]}}}' >"$CHCFG/.claude.json"
: >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" uninstall claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel uninstall leaves another kibitzer installation's record untouched" \
  '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ] &&
   [ "$(jq -r '\''.mcpServers["kibitz-channel"].command'\'' "$CHCFG/.claude.json")" = "$OTHERBIN/kibitzer" ]'
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel install refuses it too, without --replace-channel" \
  '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ]'

# An upgrade overwrites files but does not delete one the new version dropped,
# so a copy installed before the named-server channel keeps its .mcp.json and
# keeps starting the second consumer.
printf '{"mcpServers":{"kibitz":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/kibitzer","args":["channel"]}}}\n' \
  >"$AGENTSKILL/.mcp.json"
printf '{}\n' >"$CHCFG/.claude.json"; : >"$CHROOT/claude.log"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >"$WORK/chan-stale.out" 2>&1
check "channel install removes a superseded plugin .mcp.json left by an upgrade" \
  '[ ! -e "$AGENTSKILL/.mcp.json" ]' "$(cat "$WORK/chan-stale.out")"
printf '{"mcpServers":{"kibitz":{"command":"/somewhere/else/bin/kibitzer","args":["channel"]}}}\n' \
  >"$AGENTSKILL/.mcp.json"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >"$WORK/chan-foreign.out" 2>&1
check "the same shape pointing at another executable is left alone" \
  '[ -e "$AGENTSKILL/.mcp.json" ]' "$(cat "$WORK/chan-foreign.out")"
printf '{"mcpServers":{"someone-else":{"command":"/bin/true","args":["serve"]}}}\n' \
  >"$AGENTSKILL/.mcp.json"
eval "$CHENV \"$AGENTSKILL/bin/kibitzer\" install claude-channel-user" >"$WORK/chan-keep.out" 2>&1
check "an .mcp.json that is not that file is reported, never deleted" \
  '[ -e "$AGENTSKILL/.mcp.json" ] && grep >/dev/null "leaving it in place" "$WORK/chan-keep.out"' \
  "$(cat "$WORK/chan-keep.out")"
rm -f "$AGENTSKILL/.mcp.json"

LOCALSKILL="$CHROOT/project-copy"
cp -a "$PLUG" "$LOCALSKILL"
printf '{}\n' >"$CHCFG/.claude.json"; : >"$CHROOT/claude.log"
eval "$CHENV \"$LOCALSKILL/bin/kibitzer\" install claude-channel-user" >/dev/null 2>&1
CHRC=$?
check "channel install applies the transient-path guard" '[ "$CHRC" -ne 0 ] && [ ! -s "$CHROOT/claude.log" ]'
eval "$CHENV \"$LOCALSKILL/bin/kibitzer\" install claude-channel-user --force" >/dev/null 2>&1
check "channel --force only overrides the transient-path declaration" \
  'grep >/dev/null "add kibitz-channel" "$CHROOT/claude.log"'

echo
echo "upgrade from the two-file state layout"

# An install enabled under the old scheme has `enabled` and no `state`. Without
# a migration it reads as disabled and silently stops watching after an upgrade.
MIG="$(mktemp -d)"
MIGH="$(printf '%s' "$MIG" | cksum | tr -d ' ' | cut -c1-12)"
mkdir -p "$ADVISOR_STATE_ROOT/projects/$MIGH"
: >"$ADVISOR_STATE_ROOT/projects/$MIGH/enabled"
check "a legacy enabled flag is honoured after upgrade" \
  '"$ADV" status "$MIG" | grep >/dev/null "enabled : yes"' "$("$ADV" status "$MIG" | head -2)"
check "the legacy flag is adopted into the state file" \
  '[ "$(cut -d" " -f1 "$ADVISOR_STATE_ROOT/projects/$MIGH/state")" = "1" ]'
check "the legacy flag is removed once adopted" \
  '[ ! -f "$ADVISOR_STATE_ROOT/projects/$MIGH/enabled" ]'
"$ADV" off "$MIG" >/dev/null
check "off after migration is authoritative and stays off" \
  '"$ADV" status "$MIG" | grep >/dev/null "enabled : no"' "$("$ADV" status "$MIG" | head -2)"
# Re-running status must not resurrect the flag from a stale file on disk.
: >"$ADVISOR_STATE_ROOT/projects/$MIGH/enabled"
check "a stale legacy flag cannot re-enable once state exists" \
  '"$ADV" status "$MIG" | grep >/dev/null "enabled : no"' "$("$ADV" status "$MIG" | head -2)"
rm -rf "$MIG"

echo
echo "the constructive half"

check "the prompt invites more than fault-finding" \
  'grep -qi "wider than" "$HERE/../skills/kibitz/lib/prompt.tmpl" &&
   grep -qi "simpler way" "$HERE/../skills/kibitz/lib/prompt.tmpl"'
check "advisories carry a free-text kind" \
  'jq -e ".properties.advisories.items.required | index(\"kind\")" "$HERE/../skills/kibitz/lib/advice.schema.json" >/dev/null'
check "kind is free text, not an enum" \
  '! jq -e ".properties.advisories.items.properties.kind | has(\"enum\")" "$HERE/../skills/kibitz/lib/advice.schema.json" >/dev/null'

KINDBIN="$WORK/kindbin"; mkdir -p "$KINDBIN"
cat >"$KINDBIN/codex" <<'FAKE'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && cat >"$out" <<'JSON'
{"advisories":[
 {"kind":"simpler approach","note":"the retry loop duplicates backoff already in util","why_it_matters":"one place to change","evidence":"","confidence":0.8},
 {"kind":"worth preserving","note":"the read-only sandbox is load-bearing","why_it_matters":"easy to lose in a refactor","evidence":"bin/x:10","confidence":0.9}
]}
JSON
exit 0
FAKE
chmod +x "$KINDBIN/codex"
"$ADV" on "$WORK" >/dev/null; rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl" "$(sdir)/kinds"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
wait_idle
PATH="$KINDBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "a suggestion with no file evidence is still published" \
  '[ "$(find "$(sdir)/outbox" -name "*.json" | wc -l)" -eq 2 ]'
check "the operator log shows the kind" \
  'grep -q "(simpler approach)" "$(sdir)/advice.log"'
out="$(fire PreToolUse)"
check "the injected block labels each advisory with its kind" \
  'printf "%s" "$out" | jq -r ".hookSpecificOutput.additionalContext" | grep >/dev/null "\[simpler approach\]"'
check "stats reports what kinds were offered" \
  '"$ADV" stats "$WORK" | grep >/dev/null "worth preserving"'

# mute
"$ADV" mute "simpler approach" "$WORK" >/dev/null
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"; find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
wait_idle
PATH="$KINDBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "mute suppresses a matching advisory" \
  '! find "$(sdir)/outbox" -name "*.json" | xargs -r cat | grep >/dev/null "simpler approach"'
check "mute leaves everything else alone" \
  'find "$(sdir)/outbox" -name "*.json" | xargs -r cat | grep >/dev/null "worth preserving"'
check "mute list shows the pattern" '"$ADV" mute list "$WORK" | grep >/dev/null "simpler approach"'
# A topic muted after an advisory is already queued must not still be delivered.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
plant id-quiettopic "flaky test detector says hello"
"$ADV" mute "flaky test detector" "$WORK" >/dev/null
check "mute also suppresses an advisory already queued for delivery" \
  '[ -z "$(fire PreToolUse)" ]' "a muted topic was delivered from the outbox"
"$ADV" mute clear "$WORK" >/dev/null
check "mute clear empties it" '"$ADV" mute list "$WORK" | grep >/dev/null "nothing muted"'

echo
echo "register (decision 7)"

check "no gate language in the prompt sent to Codex" \
  '"$ADV" lint "$HERE/../skills/kibitz/lib/prompt.tmpl" >/dev/null'
check "no severity or verdict field in the advice schema" \
  '! jq -e ".. | objects | has(\"severity\") or has(\"verdict\")" "$HERE/../skills/kibitz/lib/advice.schema.json" | grep >/dev/null true'
check "schema permits an empty advisory list" \
  '[ "$(jq -r ".properties.advisories.minItems // 0" "$HERE/../skills/kibitz/lib/advice.schema.json")" = "0" ]'

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
wait_idle
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
: >"$CAPTURE"; rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
wait_idle
PATH="$FAKEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "operator log records advisories even while injection is quiet" \
  '[ "$(grep -c "captured" "$(sdir)/advice.log")" -ge 2 ]'
"$ADV" quiet off "$WORK" >/dev/null

# The other half of that promise: if the log cannot be written, nothing is
# published either. An advisory Claude may see and the log may not is the one
# ordering that makes "a complete log" false.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
mv "$(sdir)/advice.log" "$WORK/advice.log.bak"
mkdir "$(sdir)/advice.log"        # unwritable as a file: appends now fail
: >"$CAPTURE"; rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
wait_idle
PATH="$FAKEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "an advisory that cannot be logged is not published" \
  '[ -z "$(find "$(sdir)/outbox" -name "*.json" 2>/dev/null)" ]' \
  "published without a log entry: $(find "$(sdir)/outbox" -name '*.json' 2>/dev/null)"
rmdir "$(sdir)/advice.log"; mv "$WORK/advice.log.bak" "$(sdir)/advice.log"

# ...and the advisory is not deduplicated away by the failed attempt. Marking it
# seen before the log succeeds turns a transient outage into permanent omission:
# never published, never logged, and skipped for the rest of the session.
BEFORE_LOG="$(grep -c "captured" "$(sdir)/advice.log")"
: >"$CAPTURE"
wait_idle
PATH="$FAKEBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
check "an advisory the log rejected is offered again once the log recovers" \
  '[ "$(grep -c "captured" "$(sdir)/advice.log")" -gt "$BEFORE_LOG" ]' \
  "still suppressed after recovery; seen was written before the log"
# ...and it is genuinely deliverable, not merely logged. Logging it and then
# dropping it at the outbox write would pass the assertion above.
check "the recovered advisory reaches Claude, not just the log" \
  'printf "%s" "$(fire PreToolUse)" | jq -r ".hookSpecificOutput.additionalContext" |
     grep >/dev/null "captured"' \
  "logged after recovery but never published"

echo
echo "issue identity — the same claim about the same code, however worded"

# The old dedup hashed the whole note, so a rephrased restatement was a new
# advisory. One concern arrived 25 times in a single session under 14 kinds.
IDBIN="$WORK/idbin"; mkdir -p "$IDBIN"
SUBJ="$WORK/subject.ts"
printf 'export const a = 1\n' >"$SUBJ"
idfake() {   # $1 = note, $2 = why, $3 = evidence
  cat >"$IDBIN/codex" <<FAKE
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cat >"\$out" <<'JSON'
{"advisories":[{"kind":"k","note":"$1","why_it_matters":"$2","evidence":"$3","confidence":0.9}]}
JSON
exit 0
FAKE
  chmod +x "$IDBIN/codex"
}
idrun() { wait_idle; PATH="$IDBIN:$PATH" "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1; }
published() { find "$(sdir)/outbox" -name '*.json' 2>/dev/null | wc -l; }

"$ADV" on "$WORK" >/dev/null
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl" "$(sdir)/repeats" "$(sdir)/kinds"
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
# The two claims below are real restatements from the session that motivated
# this, lightly de-punctuated. Synthetic paraphrases are a poor test: an advisor
# reuses far more of its own vocabulary than a person inventing a reworded
# example does, and tuning the threshold against invented text would set it for
# a phenomenon that does not occur.
N1="Replacing an existing channel removes it before adding the new one. If claude mcp add fails, an owned registration has already been deleted, contrary to the otherwise preservation-oriented contract."
W1="A transient CLI failure converts a failed install into lost user configuration."
N2="The replacement path deletes the existing registration before adding the new one. If claude mcp add fails, an owned registration is lost; add a failure-path test and decide on a rollback strategy before calling this preservation-oriented UX complete."
W2="A transient CLI or config failure currently converts a failed install into destructive state change."
N3="The fallback in isOurChannel is broader than its comment: even when the resolved command differs from this executable, the unconditional suffix test accepts any path ending in bin/kibitzer."
W3="This defeats the stated preservation guarantee for a plausible name collision."

idfake "$N1" "$W1" "subject.ts:10-20"
idrun
check "a new claim is published and registered" \
  '[ "$(published)" -eq 1 ] && [ "$(wc -l <"$(sdir)/issues.jsonl")" -eq 1 ]'

find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
idfake "$N2" "$W2" "subject.ts:14-22"
idrun
check "the same claim reworded, over unchanged code, is held back" \
  '[ "$(published)" -eq 0 ] && [ -s "$(sdir)/repeats" ]' "published $(published)"

# Different problem, same file: citing one file is not enough to be a repeat,
# because a file holds many separate problems.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
idfake "$N3" "$W3" "subject.ts:40"
idrun
check "a different claim about the same file still gets through" \
  '[ "$(published)" -eq 1 ]' "published $(published)"

# Changed evidence is new evidence. The wording differs again from N2, because
# byte-identical text is held by the literal cache regardless -- that exception
# is deliberate and is what keeps a note the tokeniser cannot segment from
# collapsing into the first one.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
printf 'export const a = 2  // edited\n' >"$SUBJ"
idfake "The replacement path removes the existing registration before adding the new one. If claude mcp add fails, an owned registration is lost with no rollback; add a failure-path test before calling this preservation-oriented UX complete." \
       "$W2" "subject.ts:14-22"
idrun
check "once the cited file changes, the claim is allowed again" \
  '[ "$(published)" -eq 1 ]' "published $(published)"

# Marking. The advisor cannot observe an outcome, so nothing is recorded until
# somebody says so -- and an id that does not resolve writes nothing at all.
FIRST="$(head -1 "$(sdir)/issues.jsonl" | jq -r .id | cut -c1-6)"
OUTBEFORE="$(cat "$(sdir)/outcomes.jsonl" 2>/dev/null | wc -l)"
"$ADV" mark zzzzzz declined "$WORK" >/dev/null 2>&1; MRC=$?
check "an id that names nothing fails and records nothing" \
  '[ "$MRC" -ne 0 ] && [ "$(cat "$(sdir)/outcomes.jsonl" 2>/dev/null | wc -l)" -eq "$OUTBEFORE" ]'
"$ADV" mark "$FIRST" nonsense "$WORK" >/dev/null 2>&1; MRC=$?
check "an outcome that is not one of the four is refused" '[ "$MRC" -ne 0 ]'
"$ADV" mark "" accepted "$WORK" >/dev/null 2>&1; MRC=$?
check "an empty id is refused rather than matching everything" '[ "$MRC" -ne 0 ]'
"$ADV" mark "$FIRST" accepted "$WORK" >/dev/null 2>&1
check "a resolvable id records the outcome" \
  'grep >/dev/null "\"accepted\"" "$(sdir)/outcomes.jsonl"'
# Only `superseded` names a second advisory, so only there does a third word mean
# an id. Otherwise `mark <id> accepted /repo` would read the directory as one.
"$ADV" mark "$FIRST" superseded "$WORK" >/dev/null 2>&1; MRC=$?
check "superseded without the id it duplicates is refused" '[ "$MRC" -ne 0 ]'

# Evidence is model-written text, and pathsSignature goes on to read whatever it
# names. A non-leading traversal clears a startsWith("..") check while pointing
# anywhere on the filesystem, so the boundary is resolved, not spelled.
cat >"$WORK/citecheck.ts" <<EOF
import { citedPaths } from "$HERE/../skills/kibitz/src/core.ts"
const outside = citedPaths("x/../../../../../etc/passwd:1 /etc/passwd:2 ../../etc/hosts:3", process.cwd())
const inside = citedPaths("inside.txt:7", process.cwd())
console.log(outside.length, inside.length)
EOF
printf 'x\n' >"$WORK/inside.txt"
CITE="$(cd "$WORK" && bun "$WORK/citecheck.ts" 2>&1)"
check "a citation cannot escape the project it cites, but still finds what is in it" \
  '[ "$CITE" = "0 1" ]' "expected '0 1', got '$CITE'"

# Declining is how an operator ends a disagreement: it stays quiet even when the
# cited code moves again, which is the one thing a signature check cannot do.
LAST="$(tail -1 "$(sdir)/issues.jsonl" | jq -r .id | cut -c1-6)"
"$ADV" mark "$LAST" declined "$WORK" >/dev/null 2>&1
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
printf 'export const a = 3  // edited again\n' >"$SUBJ"
idfake "Refreshing an owned channel deletes the existing registration before adding the new one, and if claude mcp add fails the previous working registration is lost with no rollback." \
       "$W2" "subject.ts:14-22"
idrun
check "a declined issue stays quiet even after its evidence changes" \
  '[ "$(published)" -eq 0 ]' "published $(published)"

check "stats separates volume from distinct issues and outcomes" \
  '"$ADV" stats "$WORK" | grep >/dev/null "distinct issues" &&
   "$ADV" stats "$WORK" | grep >/dev/null "repeats held back" &&
   "$ADV" stats "$WORK" | grep >/dev/null "unmarked"' "$("$ADV" stats "$WORK")"

check "the operator log carries the id the mark command takes" \
  'grep >/dev/null "$FIRST" "$(sdir)/advice.log"'
# Captured before the cases below add to, and then reset, this direction's register.
CLAUDE_ISSUES="$(wc -l <"$(sdir)/issues.jsonl")"

# Containment divides by the smaller token set, so a three-word note scores 1.0
# against any longer note that happens to contain those three words. With no
# citation there is nothing else to check the claim against, so the floor has to
# guard the uncited branch too: it is the branch with no second opinion.
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
idfake "The cache is not invalidated when the registration changes, so a stale entry survives an upgrade and the channel keeps using it." \
       "Stale state outlives the change that should have cleared it." ""
idrun
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
idfake "cache not invalidated" "b" ""
idrun
check "a short uncited claim is not swallowed by a longer one that contains its words" \
  '[ "$(published)" -eq 1 ]' "published $(published)"

# mute now matches the evidence too, so a whole file can be muted by path.
"$ADV" mute "subject.ts" "$WORK" >/dev/null
find "$(sdir)/outbox" -name '*.json' -delete 2>/dev/null
rm -f "$(sdir)/seen" "$(sdir)/issues.jsonl"
idfake "something entirely unrelated about caching" "b" "subject.ts:1"
idrun
check "mute matches a path in the evidence, not only the note" \
  '[ "$(published)" -eq 0 ]' "published $(published)"
"$ADV" mute clear "$WORK" >/dev/null

# Both directions. Codex-advises-Claude ran above; this is Claude-advises-Codex,
# which differs only in the runner upstream of the shared publication loop. The
# stand-ins keep the real argument shape: bwrap execs what follows its `--`, and
# the Claude runner reads its result from stdout as a success envelope.
CXROOT="$(mktemp -d)"; CXBIN="$WORK/cxbin"; mkdir -p "$CXBIN"
cat >"$CXBIN/bwrap" <<'FAKE'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do [ "$1" = "--" ] && { shift; break; }; shift; done
exec "$@"
FAKE
cat >"$CXBIN/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"subtype":"success","structured_output":{"advisories":[
 {"kind":"k","note":"Replacing an existing channel removes it before adding the new one. If claude mcp add fails, an owned registration has already been deleted, contrary to the otherwise preservation-oriented contract.",
  "why_it_matters":"A transient CLI failure converts a failed install into lost user configuration.","evidence":"subject.ts:10-20","confidence":0.9}]}}
JSON
FAKE
chmod +x "$CXBIN/bwrap" "$CXBIN/claude"
cxsdir() {
  local h; h="$(printf '%s' "$WORK" | cksum | tr -d ' ' | cut -c1-12)"
  printf '%s/projects/%s/sessions/%s' "$CXROOT" "$h" "$SID"
}
cxrun() {
  ADVISOR_STATE_ROOT="$CXROOT" KIBITZ_HOST=codex PATH="$CXBIN:$PATH" \
    "$ADV" worker "$WORK" "$SID" "" >/dev/null 2>&1
}
ADVISOR_STATE_ROOT="$CXROOT" KIBITZ_HOST=codex "$ADV" on --host codex "$WORK" >/dev/null 2>&1
cxrun
CXN="$(find "$(cxsdir)/outbox" -name '*.json' 2>/dev/null | wc -l)"
check "the Codex direction publishes and registers through the same loop" \
  '[ "$CXN" -eq 1 ] && [ -s "$(cxsdir)/issues.jsonl" ]' "published $CXN"
find "$(cxsdir)/outbox" -name '*.json' -delete 2>/dev/null
cat >"$CXBIN/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"subtype":"success","structured_output":{"advisories":[
 {"kind":"k2","note":"The replacement path deletes the existing registration before adding the new one. If claude mcp add fails, an owned registration is lost; add a failure-path test and decide on a rollback strategy before calling this preservation-oriented UX complete.",
  "why_it_matters":"A transient CLI or config failure currently converts a failed install into destructive state change.","evidence":"subject.ts:14-22","confidence":0.9}]}}
JSON
FAKE
chmod +x "$CXBIN/claude"
cxrun
check "and holds back a rewording of it, exactly as the Claude direction does" \
  '[ "$(find "$(cxsdir)/outbox" -name "*.json" 2>/dev/null | wc -l)" -eq 0 ]'
check "each direction keeps its own register, not a shared one" \
  '[ "$(cxsdir)" != "$(sdir)" ] && [ "$(wc -l <"$(cxsdir)/issues.jsonl")" -eq 1 ] &&
   [ "$CLAUDE_ISSUES" -eq 3 ]' \
  "codex $(wc -l <"$(cxsdir)/issues.jsonl") / claude $CLAUDE_ISSUES"
rm -rf "$CXROOT"

echo
echo "hot path"

t0=$(date +%s%N); fire PreToolUse >/dev/null; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
check "drain hook completes well inside the 2s hook budget (${ms}ms)" '[ "$ms" -lt 500 ]' "${ms}ms"

echo
printf '  %s passed, %s failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
