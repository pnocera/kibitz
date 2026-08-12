#!/usr/bin/env bash
# Crosses the Claude Code loader boundary, which run-tests.sh deliberately does
# not: it installs into the exact layout `npx skills add pnocera/kibitz -g -a claude-code codex`
# produces, starts a real headless session, and asserts a hook actually fired.
#
# Not part of the default suite: it needs an authenticated Claude Code with a
# readable credentials file (or KIBITZ_CLAUDE_CREDENTIALS_JSON) and takes a
# couple of minutes, so CI cannot run it. Run it by hand after touching the
# plugin manifest, hooks/hooks.json, the install layout, or path resolution.
#
#   bash tests/smoke-plugin.sh --host claude
#   bash tests/smoke-plugin.sh --host codex
#
# Why it exists: the package combines ordinary skill discovery (SKILL.md in a
# skills directory) with plugin hook discovery (.claude-plugin + hooks/hooks.json).
# Those are separate code paths in the loader. A change can leave the skill
# discoverable while hooks silently stop registering, and every JSON-shape test
# stays green in that state -- which is exactly the failure this package shipped
# once already.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUG="${KIBITZ_PLUGIN_DIR:-$HERE/../skills/kibitz}"

host=claude
if [ "${1:-}" = "--host" ]; then
  host="${2:-}"
  shift 2
fi
[ "$#" -eq 0 ] || { echo "usage: bash tests/smoke-plugin.sh [--host claude|codex]" >&2; exit 2; }
[ "$host" = claude ] || [ "$host" = codex ] || { echo "smoke: --host must be claude or codex" >&2; exit 2; }

if [ "$host" = codex ]; then
  command -v codex >/dev/null || { echo "smoke: codex not on PATH"; exit 2; }
  AUTH_SOURCE="${KIBITZ_CODEX_AUTH_JSON:-${CODEX_HOME:-$HOME/.codex}/auth.json}"
  [ -r "$AUTH_SOURCE" ] || {
    echo "smoke: no readable local Codex credential at $AUTH_SOURCE." >&2
    echo "  Sign in with 'codex --login', or set KIBITZ_CODEX_AUTH_JSON to its auth.json path." >&2
    exit 2
  }
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "smoke: Codex host smoke needs an interactive terminal for normal hook trust." >&2
    echo "  Run: bash tests/smoke-plugin.sh --host codex" >&2
    exit 2
  fi

  umask 077
  ROOT="$(mktemp -d)"
  TEST_HOME="$ROOT/home"
  CODEX_ROOT="$ROOT/codex"
  PROJ="$ROOT/project"
  trap 'rm -rf "$ROOT"' EXIT
  mkdir -p "$TEST_HOME/.agents/skills" "$PROJ"
  # CODEX_HOME also owns auth.json. Copy the already-authenticated local
  # credential into the 0700 disposable root; it is never printed and the trap
  # removes it after the trust smoke finishes.
  mkdir -p "$CODEX_ROOT"
  cp "$AUTH_SOURCE" "$CODEX_ROOT/auth.json" || {
    echo "smoke: could not copy local Codex credentials" >&2
    exit 1
  }
  chmod 600 "$CODEX_ROOT/auth.json" || {
    echo "smoke: could not protect temporary Codex credentials" >&2
    exit 1
  }
  cp -aL "$PLUG" "$TEST_HOME/.agents/skills/kibitz" || {
    echo "smoke: could not install the Codex skill layout" >&2
    exit 1
  }
  INSTALLED="$TEST_HOME/.agents/skills/kibitz"

  CODEX_HOME="$CODEX_ROOT" "$INSTALLED/bin/kibitzer" install codex-user >/dev/null || {
    echo "smoke: could not register disposable Codex hooks" >&2
    exit 1
  }
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | contains("hook --host codex UserPromptSubmit")' \
    "$CODEX_ROOT/hooks.json" >/dev/null || { echo "smoke: Codex hook registration missing" >&2; exit 1; }
  CODEX_HOME="$CODEX_ROOT" "$INSTALLED/bin/kibitzer" on --host codex "$PROJ" >/dev/null

  cat <<EOF
smoke: starting an interactive Codex session with a disposable CODEX_HOME.
Approve the normal hook-trust prompt for $CODEX_ROOT/hooks.json, submit any
ordinary prompt, then exit Codex. Do not use a trust-bypass flag.
EOF
  ( cd "$PROJ" && HOME="$TEST_HOME" CODEX_HOME="$CODEX_ROOT" codex )

  h="$(printf '%s' "$PROJ" | cksum | tr -d ' ' | cut -c1-12)"
  if [ -f "$CODEX_ROOT/advisor/projects/$h/current-session" ]; then
    echo "smoke: PASS — trusted Codex hook created Codex-host session state"
    exit 0
  fi
  cat >&2 <<EOF
smoke: FAIL — no Codex-host session state was created.
Check that normal hook trust was approved, a prompt was submitted, and Codex
started with the disposable CODEX_HOME printed above.
EOF
  exit 1
fi

command -v claude >/dev/null || { echo "smoke: claude not on PATH"; exit 2; }
CLAUDE_AUTH_SOURCE="${KIBITZ_CLAUDE_CREDENTIALS_JSON:-$HOME/.claude/.credentials.json}"
[ -r "$CLAUDE_AUTH_SOURCE" ] || {
  echo "smoke: no readable local Claude credential at $CLAUDE_AUTH_SOURCE." >&2
  echo "  Sign in with Claude Code, or set KIBITZ_CLAUDE_CREDENTIALS_JSON to its credentials file." >&2
  exit 2
}

umask 077
ROOT="$(mktemp -d)"
TEST_HOME="$ROOT/home"
CFG="$TEST_HOME/.claude"; mkdir -p "$CFG/skills" "$TEST_HOME/.agents/skills"
STATE="$ROOT/state"
PROJ="$ROOT/project"; mkdir -p "$PROJ"
trap 'rm -rf "$ROOT"' EXIT
# The isolated config needs an authenticated Claude client to execute the
# positive command probe below. The copied credential remains in the private
# temporary root and is removed by the trap.
cp "$CLAUDE_AUTH_SOURCE" "$CFG/.credentials.json" || {
  echo "smoke: could not copy local Claude credentials" >&2
  exit 1
}
chmod 600 "$CFG/.credentials.json" || {
  echo "smoke: could not protect temporary Claude credentials" >&2
  exit 1
}

# The standard npx layout has a real Codex directory and Claude's skill is a
# relative symlink to it. This crosses both the symlink and Claude loader
# boundaries rather than merely checking a copied directory.
cp -aL "$PLUG" "$TEST_HOME/.agents/skills/kibitz" || {
  echo "smoke: could not install the Claude skill layout" >&2
  exit 1
}
ln -s ../../.agents/skills/kibitz "$CFG/skills/kibitz" || {
  echo "smoke: could not create the Claude skills symlink" >&2
  exit 1
}
[ -f "$CFG/skills/kibitz/.claude-plugin/plugin.json" ] || { echo "smoke: manifest missing"; exit 1; }

ADVISOR_STATE_ROOT="$STATE" "$CFG/skills/kibitz/bin/kibitzer" on "$PROJ" >/dev/null
H="$(printf '%s' "$PROJ" | cksum | tr -d ' ' | cut -c1-12)"

OUT="$PROJ/kibitzer-status.txt"
WHICH="$PROJ/kibitzer-path.txt"
RUN_LOG="$PROJ/claude-output.txt"
echo "smoke: starting a headless session (this takes a minute)…"
if ! ( cd "$PROJ" && CLAUDE_CONFIG_DIR="$CFG" ADVISOR_STATE_ROOT="$STATE" \
    timeout 180 claude -p "Run this Bash script exactly:
command -v kibitzer > \"$WHICH\"
kibitzer status \"$PROJ\" > \"$OUT\"
Then reply with exactly: smoke" \
    --permission-mode bypassPermissions >"$RUN_LOG" 2>&1 ); then
  echo "smoke: FAIL — headless Claude session failed." >&2
  sed -n '1,80p' "$RUN_LOG" >&2
  exit 1
fi

resolved="$(cat "$WHICH" 2>/dev/null || true)"
expected="$CFG/skills/kibitz/bin/kibitzer"
if [ "$resolved" != "$expected" ] && \
   [ "$(readlink -f "$resolved" 2>/dev/null || true)" != "$(readlink -f "$expected")" ]; then
  echo "smoke: FAIL — Claude Bash PATH did not resolve this installed kibitzer." >&2
  echo "  resolved: ${resolved:-<nothing>}" >&2
  echo "  expected: $expected" >&2
  sed -n '1,80p' "$RUN_LOG" >&2
  exit 1
fi
if ! grep -q 'enabled : yes' "$OUT"; then
  echo "smoke: FAIL — Claude did not run kibitzer status against the enabled smoke state." >&2
  sed -n '1,80p' "$OUT" >&2
  sed -n '1,80p' "$RUN_LOG" >&2
  exit 1
fi

# Optional second phase: the channel, which only registers when Claude is
# launched with the development-channel flag. Unit tests can prove the queue
# logic and the .mcp.json shape, but not that Claude discovers and launches it.
if [ "${SMOKE_CHANNEL:-0}" = "1" ]; then
  echo "smoke: channel phase — starting a session, then seeding ITS queue…"
  SD="$STATE/projects/$H/sessions"
  before="$(ls "$SD" 2>/dev/null | sort | tr '\n' ' ')"
  # The channel binds to the session that owns it, so the advisory has to be
  # queued for that session -- seeding an earlier session's outbox proves
  # nothing, and would fail even when loading works correctly.
  ( cd "$PROJ" && CLAUDE_CONFIG_DIR="$CFG" ADVISOR_STATE_ROOT="$STATE" \
      timeout 180 claude -p "Run this bash command: sleep 40" \
      --dangerously-load-development-channels "plugin:kibitz@skills-dir" \
      --permission-mode bypassPermissions >"$PROJ/chan.txt" 2>&1 ) &
  CLAUDE_PID=$!
  NEWSID=""
  for _ in $(seq 1 120); do
    for d in $(ls "$SD" 2>/dev/null); do
      case " $before " in *" $d "*) ;; *) NEWSID="$d"; break ;; esac
    done
    [ -n "$NEWSID" ] && break
    sleep 0.5
  done
  if [ -z "$NEWSID" ]; then
    echo "smoke: channel FAIL — no new session appeared; hooks did not run." >&2
    kill "$CLAUDE_PID" 2>/dev/null; exit 1
  fi
  EP="$(cut -d' ' -f2 "$STATE/projects/$H/state")"
  mkdir -p "$SD/$NEWSID/outbox"
  printf '{"id":"smoke-chan","epoch":%s,"kind":"smoke","note":"channel smoke advisory","why_it_matters":"t","evidence":"","confidence":0.5}' \
    "$EP" >"$SD/$NEWSID/outbox/1-smoke.json"
  echo "smoke: queued for session $NEWSID; waiting for the channel to claim it…"
  claimed=0
  for _ in $(seq 1 120); do
    [ -f "$SD/$NEWSID/outbox/1-smoke.json" ] || { claimed=1; break; }
    sleep 0.5
  done
  kill "$CLAUDE_PID" 2>/dev/null; wait "$CLAUDE_PID" 2>/dev/null
  if [ "$claimed" = "1" ] && grep -q '^smoke-chan$' "$SD/$NEWSID/ledger" 2>/dev/null; then
    echo "smoke: channel PASS — the channel claimed and ledgered the advisory"
  else
    echo "smoke: channel FAIL — the advisory was never claimed by the channel." >&2
    echo "  Claude may not have registered it; check the startup notice and /mcp." >&2
    sed -n '1,15p' "$PROJ/chan.txt" >&2
    exit 1
  fi
fi

n=$(find "$STATE/projects/$H/sessions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
if [ "$n" -ge 1 ]; then
  echo "smoke: PASS — plugin hooks fired from the installed layout ($n session)"
  exit 0
fi
cat >&2 <<EOF
smoke: FAIL — no session state was created, so no hook ran.

The plugin loaded its skill but not its hooks, or did not load at all. Check:
  - $CFG/skills/kibitz/.claude-plugin/plugin.json exists and validates
    (claude plugin validate "$CFG/skills/kibitz")
  - hooks/hooks.json is at the plugin root, not inside .claude-plugin/
  - each command starts with "\${CLAUDE_PLUGIN_ROOT}"/bin/kibitzer
EOF
exit 1
