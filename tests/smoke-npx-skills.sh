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
if [ "$live" -eq 1 ] && [ -z "${CODEX_API_KEY:-}" ]; then
  echo "smoke: --live needs CODEX_API_KEY for the disposable Codex session" >&2
  exit 2
fi

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
TEST_HOME="$ROOT/home"
mkdir -p "$TEST_HOME"
echo "smoke: checking the published pnocera/kibitz package in a clean home"

# The source is positional. Keeping it before -a is material: putting it last
# is parsed as an extra agent and exits with "Missing required argument: source".
HOME="$TEST_HOME" npx --yes skills add pnocera/kibitz -g -a claude-code codex -y --copy

CLAUDE_SKILL="$TEST_HOME/.claude/skills/kibitz"
CODEX_SKILL="$TEST_HOME/.agents/skills/kibitz"
for f in "$CLAUDE_SKILL/SKILL.md" "$CLAUDE_SKILL/.claude-plugin/plugin.json" \
         "$CODEX_SKILL/SKILL.md" "$CODEX_SKILL/.codex-plugin/plugin.json" \
         "$CODEX_SKILL/install/codex-hooks.json"; do
  [ -f "$f" ] || { echo "smoke: missing installed artifact: $f" >&2; exit 1; }
done

CODEX_HOME="$ROOT/codex" "$CODEX_SKILL/bin/kibitzer" install codex-user >/dev/null
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | contains("hook --host codex UserPromptSubmit")' \
  "$ROOT/codex/hooks.json" >/dev/null || { echo "smoke: Codex bootstrap failed" >&2; exit 1; }
echo "smoke: PASS — npx skills installed both host layouts and Codex bootstrap config"

if [ "$live" -eq 1 ]; then
  KIBITZ_PLUGIN_DIR="$CLAUDE_SKILL" bash "$HERE/smoke-plugin.sh" --host claude
  KIBITZ_PLUGIN_DIR="$CODEX_SKILL" bash "$HERE/smoke-plugin.sh" --host codex
fi
