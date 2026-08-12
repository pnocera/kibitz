// Registering hooks in settings.json, for checkouts that do not live in a
// skills directory. A plugin install needs none of this.
//
// These two commands DELETE entries from a file the operator owns, so the rule
// for what counts as ours is deliberately narrow and lives in core.ts.

import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"
import { spawnSync } from "node:child_process"
import { BIN, HOME, OURS_RE, exists, mkdirp, read, rm, which } from "./core.ts"

const err = (s: string) => process.stderr.write(s + "\n")
const out = (s: string) => process.stdout.write(s + "\n")

const targetFor = (scope: string): string | null =>
  scope === "project" || scope === "claude-project" ? path.join(process.cwd(), ".claude", "settings.json")
  : scope === "user" || scope === "claude-user" ? path.join(process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), ".claude"), "settings.json")
  : scope === "codex-user" ? path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex"), "hooks.json")
  : null

const templateFor = (scope: string) => scope === "codex-user" ? "codex-hooks.json" : "hooks.json"

const CHANNEL_NAME = "kibitz-channel"

// Claude's user MCP registry is deliberately not inside ~/.claude: when
// CLAUDE_CONFIG_DIR is unset it is ~/.claude.json, otherwise it is alongside
// the configured directory. Keep this separate from settings.json above.
const channelConfigPath = () => path.join(process.env.CLAUDE_CONFIG_DIR ?? os.homedir(), ".claude.json")

/** A user-scope install writes this checkout's absolute path into the global
 *  settings, so it must not point at somewhere transient. */
const isPortableHome = () =>
  !(/\/node_modules\//.test(HOME) || (HOME.startsWith("/tmp/") && !/\/\.agents\/skills\//.test(HOME)))

interface HookEntry { hooks?: { type?: string; command?: string; timeout?: number }[] }

const isOurs = (c: unknown) => typeof c === "string" && OURS_RE.test(c)

/** Drop only OUR commands from inside each group, then discard groups left
 *  empty. Claude allows several commands in one group, so removing the whole
 *  group would delete a user command that happens to sit alongside ours. */
function stripOurs(entries: HookEntry[]): HookEntry[] {
  return entries
    .map(e => ({ ...e, hooks: (e.hooks ?? []).filter(h => !isOurs(h?.command)) }))
    .filter(e => (e.hooks ?? []).length > 0)
}

interface ChannelServer { type?: unknown; command?: unknown; args?: unknown }

/** Recognise a channel we can safely replace. Realpath covers npx skills'
 * Claude-to-agents symlink; the path suffix lets uninstall repair a record
 * after the old checkout was removed. */
function isOurChannel(entry: unknown): boolean {
  if (!entry || typeof entry !== "object") return false
  const server = entry as ChannelServer
  if (server.type !== undefined && server.type !== "stdio") return false
  if (!Array.isArray(server.args) || server.args.length !== 1 || server.args[0] !== "channel") return false
  if (typeof server.command !== "string") return false
  try {
    if (fs.realpathSync(server.command) === fs.realpathSync(BIN)) return true
  } catch {}
  return /(?:^|\/)bin\/kibitzer$/.test(server.command)
}

function readChannelEntry(): { exists: boolean; entry: unknown } | null {
  const target = channelConfigPath()
  if (!exists(target)) return { exists: false, entry: undefined }
  let config: any
  try { config = JSON.parse(read(target) ?? "") } catch {
    err(`kibitzer: ${target} is not valid JSON — refusing to touch it`); return null
  }
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    err(`kibitzer: ${target} is not a JSON object — refusing to touch it`); return null
  }
  if (config.mcpServers !== undefined && (!config.mcpServers || typeof config.mcpServers !== "object" || Array.isArray(config.mcpServers))) {
    err(`kibitzer: ${target} has a non-object mcpServers map — refusing to touch it`); return null
  }
  return { exists: Object.prototype.hasOwnProperty.call(config.mcpServers ?? {}, CHANNEL_NAME), entry: config.mcpServers?.[CHANNEL_NAME] }
}

function runClaudeMcp(args: string[]): boolean {
  if (!which("claude")) {
    err("kibitzer: Claude Code CLI is required to register the Claude channel (claude is not on PATH)")
    return false
  }
  const result = spawnSync("claude", ["mcp", ...args], { stdio: "inherit" })
  if (result.status === 0) return true
  err(`kibitzer: Claude MCP command failed${result.status === null ? "" : ` (exit ${result.status})`}`)
  return false
}

function channelUsage(): number {
  err("usage: kibitzer install claude-channel-user [--force] [--replace-channel]")
  return 2
}

function portableChannelHome(force: boolean): boolean {
  if (isPortableHome() || force) return true
  err("kibitzer: refusing a user-scope channel registration from a transient location.")
  err(`  This copy lives at: ${HOME}`)
  err("  Install kibitz somewhere stable, or re-run with --force if this path is permanent.")
  return false
}

/** Register through Claude's supported writer, never by modifying its live
 * .claude.json ourselves. The inspection is solely a narrow ownership gate. */
function cmdInstallClaudeChannel(options: string[]): number {
  if (options.some(v => v !== "--force" && v !== "--replace-channel")) return channelUsage()
  if (!portableChannelHome(options.includes("--force"))) return 1
  const current = readChannelEntry()
  if (!current) return 1
  if (current.exists && !isOurChannel(current.entry) && !options.includes("--replace-channel")) {
    err(`kibitzer: ${CHANNEL_NAME} already belongs to another MCP server in ${channelConfigPath()}`)
    err("  refusing to replace it; re-run with --replace-channel if that is intentional")
    return 1
  }
  // Claude mcp add deliberately rejects duplicate names. Removing first is
  // safe only after the exact ownership gate above (or an explicit override).
  if (current.exists && !runClaudeMcp(["remove", "--scope", "user", CHANNEL_NAME])) return 1
  if (!runClaudeMcp(["add", "--scope", "user", CHANNEL_NAME, "--", BIN, "channel"])) return 1
  const next = readChannelEntry()
  if (!next || !next.exists || !isOurChannel(next.entry)) {
    err(`kibitzer: Claude did not register the expected ${CHANNEL_NAME} entry in ${channelConfigPath()}`)
    return 1
  }
  out(`kibitzer: Claude channel registered in ${channelConfigPath()} (via Claude Code)`)
  out(`  Restart Claude with: claude --dangerously-load-development-channels server:${CHANNEL_NAME}`)
  return 0
}

function cmdUninstallClaudeChannel(options: string[]): number {
  if (options.length > 0) { err("usage: kibitzer uninstall claude-channel-user"); return 2 }
  const current = readChannelEntry()
  if (!current) return 1
  if (!current.exists) { out(`kibitzer: no ${CHANNEL_NAME} registration in ${channelConfigPath()}`); return 0 }
  if (!isOurChannel(current.entry)) {
    err(`kibitzer: ${CHANNEL_NAME} in ${channelConfigPath()} is not this kibitzer; leaving it untouched`)
    return 1
  }
  if (!runClaudeMcp(["remove", "--scope", "user", CHANNEL_NAME])) return 1
  const next = readChannelEntry()
  if (!next || next.exists) {
    err(`kibitzer: Claude did not remove ${CHANNEL_NAME} from ${channelConfigPath()}`)
    return 1
  }
  out(`kibitzer: Claude channel removed from ${channelConfigPath()}`)
  return 0
}

export function cmdInstall(scope = "project", options: string[] = []): number {
  if (scope === "claude-channel-user") return cmdInstallClaudeChannel(options)
  const force = options[0]
  const target = targetFor(scope)
  if (!target || options.length > 1 || (force !== undefined && force !== "--force")) {
    err("usage: kibitzer install [claude-project|claude-user|codex-user|claude-channel-user] [--force]")
    return 2
  }

  if ((scope === "user" || scope === "claude-user" || scope === "codex-user") && !isPortableHome() && force !== "--force") {
    err("kibitzer: refusing a user-scope install from a transient location.")
    err("  This copy lives at:")
    err(`    ${HOME}`)
    if (scope === "codex-user") {
      err("  Global Codex hooks would hard-code that path and break if it moves. Either:")
      err("    - install this skill somewhere stable and run 'kibitzer install codex-user', or")
      err("    - re-run 'kibitzer install codex-user --force' if this path is permanent.")
    } else {
      err("  Global Claude hooks would hard-code that path and break if it moves. Either:")
      err("    - clone kibitz somewhere stable and run 'kibitzer install claude-user' from there, or")
      err("    - use 'kibitzer install claude-project' here, or")
      err("    - re-run with --force if you are sure this path is permanent.")
    }
    return 1
  }
  // The hook command is a string the hook runner hands to a shell. Quoting
  // makes spaces safe; a quote, backtick, $ or backslash would end or escape
  // that quoting and turn a checkout location into shell syntax. Refuse rather
  // than escape our way out -- the plugin route has no such limit, because
  // ${CLAUDE_PLUGIN_ROOT} is expanded by the runner and not by us.
  if (/["`$'\\]/.test(HOME)) {
    err("kibitzer: refusing to install from a path containing quote, backtick,")
    err("  backslash or $ characters -- it cannot be embedded safely in a hook")
    err("  command. Move the checkout, or install it as a plugin instead:")
    err(`    ${HOME}`)
    return 1
  }

  const tmplPath = path.join(HOME, "install", templateFor(scope))
  const tmplRaw = read(tmplPath)
  if (tmplRaw === null) { err(`kibitzer: missing ${tmplPath}`); return 1 }

  mkdirp(path.dirname(target))
  if (!exists(target)) try { fs.writeFileSync(target, "{}\n") } catch {}
  const curRaw = read(target) ?? "{}"
  let cur: any
  try { cur = JSON.parse(curRaw) } catch {
    err(`kibitzer: ${target} is not valid JSON — refusing to touch it`); return 1
  }
  const tmpl = JSON.parse(tmplRaw.split("__KIBITZ__").join(BIN))

  try { fs.copyFileSync(target, `${target}.kibitz-backup`) } catch {}

  cur.hooks ??= {}
  for (const event of Object.keys(tmpl.hooks)) {
    cur.hooks[event] = [...stripOurs(cur.hooks[event] ?? []), ...tmpl.hooks[event]]
  }

  // Never write onto the live file: a truncating redirect leaves the operator
  // with empty settings if the write is interrupted, and the backup does not
  // help if the truncation is what they find first.
  const tmp = `${target}.kibitz-tmp.${process.pid}`
  try {
    fs.writeFileSync(tmp, JSON.stringify(cur, null, 2) + "\n")
    fs.renameSync(tmp, target)
  } catch {
    rm(tmp); err(`kibitzer: could not replace ${target}`); return 1
  }
  out(`kibitzer: hooks installed in ${target} (backup: ${target}.kibitz-backup)`)
  if (scope === "codex-user") {
    out("  Start Codex and approve normal hook trust for this file; do not bypass trust.")
    out("  Then start a new Codex session before enabling the Codex host.")
  } else out("  restart Claude Code — hooks are snapshotted at session start.")
  return 0
}

export function cmdUninstall(scope = "project", options: string[] = []): number {
  if (scope === "claude-channel-user") return cmdUninstallClaudeChannel(options)
  const target = targetFor(scope)
  if (!target || options.length > 0) { err("usage: kibitzer uninstall [claude-project|claude-user|codex-user|claude-channel-user]"); return 2 }
  if (!exists(target)) { out(`kibitzer: nothing at ${target}`); return 0 }

  let cur: any
  try { cur = JSON.parse(read(target) ?? "") } catch {
    err(`kibitzer: could not rewrite ${target} — hooks left in place`); return 1
  }
  // Leave a file with no hooks exactly as it is: there is nothing of ours to
  // clean, and inventing an empty hooks key would mean writing to it anyway.
  if (cur && typeof cur === "object" && "hooks" in cur && cur.hooks) {
    const next: Record<string, HookEntry[]> = {}
    for (const [event, entries] of Object.entries(cur.hooks as Record<string, HookEntry[]>)) {
      const kept = stripOurs(entries ?? [])
      if (kept.length > 0) next[event] = kept
    }
    cur.hooks = next
  }
  const tmp = `${target}.tmp`
  try {
    fs.writeFileSync(tmp, JSON.stringify(cur, null, 2) + "\n")
    fs.renameSync(tmp, target)
  } catch { rm(tmp); err(`kibitzer: could not replace ${target}`); return 1 }
  out(`kibitzer: hooks removed from ${target}`)
  return 0
}

/** Claude Code exposes a plugin bin/ on its Bash-tool PATH. Link the installed
 *  executable when an operator or another host needs a shell command. */
export function cmdLink(dir = path.join(os.homedir(), ".local", "bin"), force?: string): number {
  try { fs.mkdirSync(dir, { recursive: true }) } catch { err(`kibitzer: cannot create ${dir}`); return 1 }
  const dest = path.join(dir, "kibitzer")
  // Writing into a command directory: never clobber something that is not ours.
  if (exists(dest) || fs.lstatSync(dest, { throwIfNoEntry: false })) {
    let cur = ""
    try { cur = fs.realpathSync(dest) } catch {}
    let mine = ""
    try { mine = fs.realpathSync(BIN) } catch { mine = BIN }
    if (cur !== mine && force !== "--force") {
      err(`kibitzer: ${dest} already exists and is not this kibitzer`)
      err(`  it points at: ${cur || "<unreadable>"}`)
      err("  refusing to replace it; re-run with --force if that is what you want")
      return 1
    }
  }
  try { rm(dest); fs.symlinkSync(BIN, dest) } catch {
    err(`kibitzer: cannot link into ${dir}`); return 1
  }
  out(`kibitzer: linked ${dest} -> ${BIN}`)
  if (!(process.env.PATH ?? "").split(":").includes(dir))
    err(`  note: ${dir} is not on your PATH`)
  if (!isPortableHome())
    err("  note: this links to a project-local checkout; see 'kibitzer install user'")
  return 0
}
