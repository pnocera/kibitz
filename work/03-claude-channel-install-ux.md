# Claude channel install UX amendment

## Problem

`npx skills add` installs a skills-directory plugin. Claude loads that plugin's
MCP server, but the Channels preview does not treat a `skills-dir` plugin as an
installable channel plugin. The prior README required a raw `claude mcp add`
workaround, which exposes host configuration details and is not acceptable
operator UX.

## Decision

Add a managed CLI scope:

```text
kibitzer install claude-channel-user
kibitzer uninstall claude-channel-user
```

The install command owns the `kibitz-channel` entry in Claude's user-level
`mcpServers` map. It delegates registration and removal to `claude mcp` rather
than directly editing Claude's live config. This gives Claude Code ownership of
its config writer and path selection: the target is `~/.claude.json` by default
or `$CLAUDE_CONFIG_DIR/.claude.json` when that variable is set. The user then
has one public launch choice:

```text
claude --dangerously-load-development-channels server:kibitz-channel
```

This is symmetric with the existing `install codex-user` activation: package
installation is pure discovery; a named, explicit kibitzer command performs the
user-scoped registration that Claude/Codex cannot infer safely.

## Safety contract

- Existing `kibitz-channel` is updated only when it is recognisably owned: a
  stdio (or omitted-type) record with exactly `["channel"]` arguments and a
  command realpath equal to `BIN`. A `/bin/kibitzer` suffix remains removable
  after its old checkout has gone away.
- A foreign same-name entry is refused unless `--replace-channel` is supplied.
- `--force` retains its existing, distinct meaning: permit a global absolute
  registration from a transient checkout only when the operator declares it
  permanent.
- Uninstall removes only a recognisably owned `kibitz-channel` record; a foreign
  record remains untouched.
- Invalid JSON or a malformed `mcpServers` map is never modified. Missing
  registration is a successful uninstall no-op.
- The installer requires `claude` on `PATH`; this is intentional because Claude
  is the authoritative writer and avoids lost updates to its hot config file.

## Validation

Add tests for install, owned update through a symlink, foreign collision/refusal,
explicit replacement, uninstall preservation, and malformed config refusal.
Update the live channel smoke to call this command under an isolated
`CLAUDE_CONFIG_DIR`, assert its `.claude.json` registration, then start Claude
with `server:kibitz-channel` and no injected `--mcp-config`, proving the managed
user registration is the server that the development channel loads.
