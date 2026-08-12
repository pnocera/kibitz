#!/usr/bin/env bash
# Proves the published npx skills command shape and the two installed layouts.
# It validates origin/main, not uncommitted source; run it after publishing.
# `--live` then crosses the host loaders; Codex trust remains an operator action.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
live=0
if [ "${1:-}" = "--live" ]; then live=1; shift; fi
[ "$#" -eq 0 ] || { echo "usage: bash tests/smoke-npx-skills.sh [--live]" >&2; exit 2; }
command -v npx >/dev/null || { echo "smoke: npx not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
TEST_HOME="$ROOT/home"
mkdir -p "$TEST_HOME"
echo "smoke: checking the published pnocera/kibitz package in a clean home"

# The source is positional. Keeping it before -a is material: putting it last
# is parsed as an extra agent and exits with "Missing required argument: source".
# -y keeps the published command non-interactive for this smoke.
HOME="$TEST_HOME" npx --yes skills add pnocera/kibitz -g -a claude-code codex -y

CLAUDE_SKILL="$TEST_HOME/.claude/skills/kibitz"
CODEX_SKILL="$TEST_HOME/.agents/skills/kibitz"
for f in "$CLAUDE_SKILL/SKILL.md" "$CLAUDE_SKILL/.claude-plugin/plugin.json" \
         "$CODEX_SKILL/SKILL.md" "$CODEX_SKILL/.codex-plugin/plugin.json" \
         "$CODEX_SKILL/install/codex-hooks.json"; do
  [ -f "$f" ] || { echo "smoke: missing installed artifact: $f" >&2; exit 1; }
done
[ -L "$CLAUDE_SKILL" ] || { echo "smoke: expected Claude layout to be a symlink" >&2; exit 1; }
[ -d "$CODEX_SKILL" ] && [ ! -L "$CODEX_SKILL" ] || {
  echo "smoke: expected Codex layout to be a real directory" >&2
  exit 1
}

CODEX_HOME="$ROOT/codex" "$CODEX_SKILL/bin/kibitzer" install codex-user >/dev/null
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | contains("hook --host codex UserPromptSubmit")' \
  "$ROOT/codex/hooks.json" >/dev/null || { echo "smoke: Codex bootstrap failed" >&2; exit 1; }
echo "smoke: PASS — npx skills installed both host layouts and Codex bootstrap config"

if [ "$live" -eq 1 ]; then
  run_live() {
    set +e
    KIBITZ_PLUGIN_DIR="$1" bash "$HERE/smoke-plugin.sh" --host "$2"
    rc=$?
    set -e
    if [ "$rc" -eq 2 ]; then
      echo "smoke: SKIP — $2 live host smoke cannot run in this environment" >&2
      return 0
    fi
    return "$rc"
  }
  run_live "$CLAUDE_SKILL" claude
  run_live "$CODEX_SKILL" codex
fi
