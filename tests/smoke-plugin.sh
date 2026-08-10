#!/usr/bin/env bash
# Crosses the Claude Code loader boundary, which run-tests.sh deliberately does
# not: it installs into the exact layout `npx skills add -g -a claude-code`
# produces, starts a real headless session, and asserts a hook actually fired.
#
# Not part of the default suite: it needs an authenticated Claude Code and takes
# a couple of minutes, so CI cannot run it. Run it by hand after touching the
# plugin manifest, hooks/hooks.json, the install layout, or path resolution.
#
#   bash tests/smoke-plugin.sh
#
# Why it exists: the package combines ordinary skill discovery (SKILL.md in a
# skills directory) with plugin hook discovery (.claude-plugin + hooks/hooks.json).
# Those are separate code paths in the loader. A change can leave the skill
# discoverable while hooks silently stop registering, and every JSON-shape test
# stays green in that state -- which is exactly the failure this package shipped
# once already.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUG="$HERE/../skills/kibitz"

command -v claude >/dev/null || { echo "smoke: claude not on PATH"; exit 2; }

CFG="$(mktemp -d)/cfg"; mkdir -p "$CFG/skills"
STATE="$(mktemp -d)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$CFG" "$STATE" "$PROJ"' EXIT

# The layout `npx skills add -g -a claude-code` produces: the plugin directory
# sitting directly in the personal skills dir.
cp -r "$PLUG" "$CFG/skills/kibitz"
[ -f "$CFG/skills/kibitz/.claude-plugin/plugin.json" ] || { echo "smoke: manifest missing"; exit 1; }

ADVISOR_STATE_ROOT="$STATE" "$CFG/skills/kibitz/bin/kibitzer" on "$PROJ" >/dev/null
H="$(printf '%s' "$PROJ" | cksum | tr -d ' ' | cut -c1-12)"

# Also resolve the command through the Bash tool: the README's first instruction
# is `kibitzer on`, which depends on the plugin exposing bin/ on that PATH. The
# hook assertion below would still pass if that broke.
WHICH="$PROJ/which-kibitzer.txt"
echo "smoke: starting a headless session (this takes a minute)…"
( cd "$PROJ" && CLAUDE_CONFIG_DIR="$CFG" ADVISOR_STATE_ROOT="$STATE" \
    timeout 180 claude -p "Run this bash command: command -v kibitzer > $WHICH; echo smoke" \
    --permission-mode bypassPermissions >/dev/null 2>&1 )

resolved="$(cat "$WHICH" 2>/dev/null)"
want="$CFG/skills/kibitz/bin/kibitzer"
if [ "$(readlink -f "$resolved" 2>/dev/null)" = "$(readlink -f "$want")" ]; then
  echo "smoke: kibitzer resolves on the Bash tool PATH -> $resolved"
else
  cat >&2 <<EOF
smoke: FAIL — the Bash tool did not resolve kibitzer to this plugin.
  resolved: ${resolved:-<nothing>}
  expected: $want
The README's first instruction is \`kibitzer on\`, which needs the plugin to put
its bin/ on that PATH. A shadowing binary or a loader change breaks it, and the
hook assertion below would still have passed.
EOF
  exit 1
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
