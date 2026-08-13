#!/usr/bin/env bash
# Deterministic, model-free replay: the fake Claude returns recorded structured
# answers and the real Codex-host worker makes the lifecycle decision.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ADV="$HERE/../skills/kibitz/bin/kibitzer"
ROOT="$(mktemp -d)"; trap '[ -n "${KEEP_REPLAY_ROOT:-}" ] || rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home" CODEX_HOME="$ROOT/codex" ADVISOR_STATE_ROOT="$ROOT/state"
export KIBITZ_HOST=codex ADVISOR_MAX_PER_CYCLE=1
WORK="$ROOT/work"; mkdir -p "$WORK" "$ROOT/bin"; SID="ops-replay"
printf '#!/usr/bin/env bash\nwhile [ "$#" -gt 0 ]; do [ "$1" = "--" ] && { shift; exec "$@"; }; shift; done\n' >"$ROOT/bin/bwrap"; chmod +x "$ROOT/bin/bwrap"
cat >"$ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >"$PROMPT_CAPTURE"
printf '{"subtype":"success","structured_output":'
cat "$FAKE_REPLY"
printf '}\n'
EOF
chmod +x "$ROOT/bin/claude"
PATH="$ROOT/bin:$PATH" "$ADV" on --host codex "$WORK" >/dev/null
sdir() { local h; h="$(printf '%s' "$WORK" | cksum | tr -d ' ' | cut -c1-12)"; printf '%s/projects/%s/sessions/%s' "$ADVISOR_STATE_ROOT" "$h" "$SID"; }
epoch() { cut -d' ' -f2 "$(dirname "$(dirname "$(sdir)")")/state"; }
cycle() {
  local event="$1" reply="$2" prompt="$3"; mkdir -p "$(sdir)/events"
  jq -cn --argjson e "$event" --argjson ep "$(epoch)" '$e + {epoch:$ep,at:"2026-08-13T10:00:00+00:00"}' >"$(sdir)/events/one.json"
  printf '%s\n' "$reply" >"$ROOT/reply.json"; export FAKE_REPLY="$ROOT/reply.json" PROMPT_CAPTURE="$ROOT/prompt.txt"
  PATH="$ROOT/bin:$PATH" "$ADV" worker --host codex "$WORK" "$SID" "" >/dev/null
  [ -z "$prompt" ] || grep -q "$prompt" "$(sdir)/worker.log" || true
}
# First delivery: a deferred milestone concern is an open semantic issue.
TIMER='{"advisories":[{"kind":"operations","note":"Check Persistent timer catch-up before restoring timers.","claim":"Persistent timers can catch up missed jobs when restored.","timing":"milestone","evidence_freshness":"current_state","why_it_matters":"Restoring all timers together can stampede producers.","evidence":"producer.timer","confidence":0.9}]}'
cycle '{"tool":"exec_command","input":"systemctl show producer.timer -p Persistent","local_exit":0}' "$TIMER" ''
[ "$(find "$(sdir)/outbox" -name '*.json' | wc -l)" -eq 1 ]
rm -f "$(sdir)/outbox"/*.json
# Same evidence during a poll is held, but remains pull-visible.
cycle '{"tool":"exec_command","input":"systemctl is-active producer.timer","local_exit":0}' "$TIMER" ''
[ "$(find "$(sdir)/outbox" -name '*.json' | wc -l)" -eq 0 ]
PATH="$ROOT/bin:$PATH" "$ADV" open --host codex "$WORK" | grep -q 'Persistent timers'
ISSUE_ID="$(jq -r '.id' "$(sdir)/issues.jsonl")"
# Feedback remains append-only after the delivery file has gone; it is never on
# the hook path and summary is pull-based.
PATH="$ROOT/bin:$PATH" "$ADV" defer --host codex "$ISSUE_ID" 'waiting for restore' "$WORK" >/dev/null
PATH="$ROOT/bin:$PATH" "$ADV" summary --host codex "$WORK" | grep -q 'deferred'
[ -s "$(sdir)/issue-events.jsonl" ]
# Restore transition makes the same semantic issue eligible again.
cycle '{"tool":"exec_command","input":"systemctl enable --now producer.timer","local_exit":0}' "$TIMER" ''
[ "$(find "$(sdir)/outbox" -name '*.json' | wc -l)" -eq 1 ]
PATH="$ROOT/bin:$PATH" "$ADV" resolve --host codex "$ISSUE_ID" "$WORK" >/dev/null
PATH="$ROOT/bin:$PATH" "$ADV" reopen --host codex "$ISSUE_ID" 'new operator check' "$WORK" >/dev/null
PATH="$ROOT/bin:$PATH" "$ADV" ack --host codex "$ISSUE_ID" "$WORK" >/dev/null
grep -q 'acknowledged' "$(sdir)/issue-events.jsonl"
rm -f "$(sdir)/outbox"/*.json
# A local SSH 255 is explicitly not a remote result, and clipped output stays incomplete.
EMPTY='{"advisories":[]}'
cycle '{"tool":"exec_command","input":"ssh host systemctl status producer","local_exit":255,"error":"Control socket failed","output_truncated":true}' "$EMPTY" ''
grep -q 'remote transport unknown' "$ROOT/prompt.txt"
grep -q 'output incomplete' "$ROOT/prompt.txt"
# A --from-db rebaseline has no invented embedding warning; a fresh EnvironmentFile
# failure remains eligible and outranks deferred history.
cycle '{"tool":"exec_command","input":"sync --from-db rebaseline","local_exit":0}' "$EMPTY" ''
grep -q 'do not infer an embedding launch' "$ROOT/prompt.txt"
ENV='{"advisories":[{"kind":"launch environment","note":"The managed unit cannot load its EnvironmentFile.","claim":"The managed-unit launch path is missing its EnvironmentFile.","timing":"now","evidence_freshness":"current_activity","why_it_matters":"The restart cannot complete.","evidence":"syncd.service","confidence":0.95}]}'
cycle '{"tool":"exec_command","input":"systemctl restart syncd","local_exit":1,"error":"EnvironmentFile missing"}' "$ENV" ''
[ "$(find "$(sdir)/outbox" -name '*.json' | wc -l)" -eq 1 ]
echo 'PASS replay codex ops session'
