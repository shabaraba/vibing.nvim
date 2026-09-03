# Plugin Loading and Command Discovery

Detail behind `.claude/rules/architecture.md` → "Plugin Loading, Command Discovery and
Startup Cost". vibing.nvim's own Claude Code plugin is never installed; it is handed to the CLI
per session with `--plugin-dir`. Everything below was measured against claude 2.1.231, because
none of it is documented.

## Self-Hosted Claude Code Plugin (`--plugin-dir`)

vibing.nvim's own Claude Code plugin — the `vibing-nvim` MCP server, the bundled skills, the
`nvim-navigator` agent — is **not installed**. `cli_command_builder` passes
`--plugin-dir <path>` once per directory resolved by
`infrastructure/plugins/plugin_dirs.lua`, which loads a plugin for that CLI invocation only and
writes nothing to Claude Code's global state.

The resolved list is `self` → `.vibing/plugins/*/` → `agent.plugins.extra`, and it is the single
definition of "which plugin directories apply here": the argv, the skill completion provider and
the agent completion provider all read it rather than each re-deriving the convention.

**What this bought.** `build.sh` used to run `claude plugin marketplace add` and
`claude plugin install ... --scope user`, which produced #480/#482 (hanging `claude plugin` calls
needing a bespoke watchdog), #450, #557, and a standing marketplace-rename migration. It also
copied `claude-plugin/` into a per-version cache, so ~90 lines of rsync plus a
`mcp-server/{node_modules,dist}` symlink-back existed purely to keep that copy in step with the
checkout. All of it is gone. The structural win is the third one: the MCP server no longer
updates independently of the Neovim plugin it serves, so a worktree runs the server it contains
rather than whatever the user last installed globally.

**Measured against claude 2.1.231**, because none of it is documented:

| Question                                 | Answer                                                                        |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| Tool name under `--plugin-dir`           | `mcp__plugin_vibing-nvim_vibing-nvim__<tool>` — identical to the install      |
| What decides that prefix                 | `plugin.json`'s `name` and the `mcpServers` key. **Not** the marketplace name |
| Same-named plugin in two `--plugin-dir`s | The **earlier flag wins**; the later one's skills never load                  |
| How many `--plugin-dir` flags            | No cap found: 30 loaded, all 30 skills visible to the model                   |
| Broken / missing / absent manifest       | **Silently ignored**, exit 0, no warning                                      |
| `--strict-mcp-config`                    | Blocks the plugin's MCP servers (0 connection log lines)                      |
| Coexisting with a user-scope install     | Inline wins, no duplication, no error                                         |

Two of those rows drive design decisions rather than being trivia.

**First-wins is why the order is fixed at self → project → extra.** A `.vibing/plugins/` entry
that names itself `vibing-nvim` cannot displace the real one. `plugin_dirs.resolve_entries`
deduplicates by plugin name the same way, so the list it returns is what actually loads rather
than what the CLI was offered — which is also what lets the completion providers reuse it.

**Silent-ignore is why there is a manifest check at all.** `--plugin-dir` gives no signal
whatsoever for a directory it declines, so "I dropped a plugin in and nothing happened" would
have no explanation anywhere. `plugin_dirs` reads each candidate's `.claude-plugin/plugin.json`
first and warns about the ones it drops. The per-cwd cache is what keeps that to one notification
instead of one per request; a separate warned-once flag would be redundant with it, and would
have to survive `clear_cache()` to mean anything — silencing the warning on exactly the
`:VibingReloadCommands` the user runs after trying to fix the plugin.

**Not passed on the lightweight path**, per `core/types.lua`. `--strict-mcp-config` already
blocks the MCP servers there, but skill descriptions still cost prompt tokens on a call that has
`--tools ""` and so nothing to invoke them with.

**Completion passes the same list to the CLI rather than rediscovering it.**
`completion/cli_command_list.lua` repeats these `--plugin-dir` flags on its probe, so the CLI
namespaces those skills (`vibing-nvim:vibing-code-tour`) and reports them itself — see "Slash
Command Discovery" below. The agent provider (`completion/providers/agents.lua`) still scans the
directories itself, since no CLI query answers "which subagents are loaded"; without it
`nvim-navigator` would load in the CLI and never appear in completion.

**`:VibingReloadCommands` clears `plugin_dirs` first**, before the provider caches: both
re-resolve from it, so clearing it second would refill them from the list being discarded.

**`.vibing/plugins/` is read by default, and that is a security decision, not an oversight.** A
plugin may declare `mcpServers`, so a directory committed to a cloned repository can start a
process on the user's machine on the first message. That is a stronger thing than the instruction
injection an unreviewed `.claude/skills/` allows, and it is why Claude Code gates a project's own
`.mcp.json` behind approval. The convenience was preferred; `agent.plugins.project_dir = false`
is the opt-out.

**A worktree reads both its own `.vibing/plugins` and the project root's.** `.vibing/` is
git-ignored, so a worktree checkout usually has none of its own. This is a union with per-name
precedence, not the strict fallback `project_system_prompt.read_for_cwd` applies to
`.vibing/system-prompt.md`: that one picks a single file and so has to choose, while a _set_ of
plugins does not, and a worktree adding one experimental plugin should not lose every plugin the
project already had. Reusing a root plugin's name is still how a worktree overrides it.

**Accepted:** a plain `claude` session started outside Neovim no longer sees the `nvim_*` tools.
Reaching a running Neovim was the entire point of them, so no opt-in was added.
`.claude-plugin/marketplace.json` is kept — a manual `claude plugin install` still works, and
deleting it can happen later.

## Codex: the Same Plugins Without `--plugin-dir`

The codex backend loads the same resolved list — `plugin_dirs.resolve_entries`, same order, same
manifest check — but codex 0.153 has nothing that takes a plugin directory for one run, so the
plugin travels in two halves. `infrastructure/plugins/plugin_contents.lua` reads them and
`adapter/modules/codex_plugin_config.lua` renders them as `-c` overrides on the `codex exec`
argv; the builder appends them on every ordinary call, resumed or not, and never on a
lightweight one (`core/types.lua`).

**Measured against codex 0.153.0** (`codex debug prompt-input` renders the model-visible prompt
without calling the model; `codex exec --strict-config --ignore-user-config` rejects unknown
config keys before doing anything else, so a probe never spends a token):

| Question                                            | Answer                                                                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| A `--plugin-dir` equivalent                         | None. `codex plugin add <plugin>@<marketplace>` copies into `$CODEX_HOME` and edits `config.toml`             |
| `<repo>/.agents/plugins/marketplace.json`           | Not discovered from the cwd; only `~/.agents/plugins/marketplace.json` is implicit                            |
| `-c plugins.<id>.enabled=true`                      | Accepted (`PluginConfig`), does nothing for a plugin that was never installed                                 |
| Skill roots                                         | `$CODEX_HOME/skills`, its `.system`, and `.agents/skills` walking up from the cwd. No config adds one         |
| `-c skills.config=[{path,enabled}]`                 | Toggles a discovered skill; a path outside the roots is ignored                                               |
| Manifest forms codex itself reads                   | `.codex-plugin/`, `.claude-plugin/` and `.cursor-plugin/plugin.json`                                          |
| `-c mcp_servers.<name>.{command,args,env}`          | Starts the server in `exec` before the model call, with the `env` map applied                                 |
| `-c mcp_servers.<name>.default_tools_approval_mode` | One of `auto`, `prompt`, `writes`, `approve`                                                                  |
| `-c developer_instructions="…"`                     | Becomes the first `developer` message, ahead of codex's own; `additional_developer_instructions` is not a key |
| Quoting in the `-c` key path                        | Not parsed: `mcp_servers."a-b".command` registers a server named `"a-b"`, quotes included                     |
| Value escaping                                      | A TOML basic string round-trips `"`, `\`, `\n`, `\t` and multibyte text                                       |

The argv `codex_plugin_config` emits for the bundled plugin was then fed to
`codex exec --strict-config --ignore-user-config` as-is: every key was accepted, and codex spawned
`mcp-server/bin/run.sh` with the manifest's `env` applied and completed `initialize` and
`tools/list` before the model call. One thing that is not a property of the overrides but cost
an hour of probing: in the container this was measured in (no bubblewrap on `PATH`, codex using
its bundled one), `codex exec` with _any_ `mcp_servers` entry — a three-line echo server
included — stalled on most runs before spawning the server, with nothing on stderr and the
banner never printed, and started normally on others, with the same arguments, a fresh
`CODEX_HOME`, and the network refused. It never correlated with which overrides were passed.
A start that looks dead is worth one retry before it is read as a config problem.

Four of those rows decide the shape.

**MCP servers go through `-c mcp_servers.<name>.*`, with `default_tools_approval_mode="approve"`.**
Headless `codex exec` cancels an MCP call at its own approval prompt — stdin is closed, so EOF
reads as a denial ([openai/codex#24135](https://github.com/openai/codex/issues/24135)) — and
`approve` is the only one of the four values that never reaches that prompt. It is per server,
so nothing else in the user's `config.toml` changes, and the decision that matters stays with
vibing.nvim's own PreToolUse hook, exactly as it does for every other tool. `${CLAUDE_PLUGIN_ROOT}`
is expanded to the plugin directory in `command`, `args` and `env` alike, the same substitution
Claude Code performs, and the `"mcpServers": "./.mcp.json"` file form is followed. Servers are
deduplicated by name with the first plugin winning, which is `--plugin-dir`'s precedence for a
duplicate plugin name: a project plugin cannot put its own command behind `mcp__vibing-nvim__*`.
The tools appear under the plain `mcp__vibing-nvim__<tool>` prefix, which
`can_use_tool.is_vibing_nvim_mcp_tool` already accepts.

**Skills go through `developer_instructions`, because there is no skill root to add.** The roots
codex scans are the user's own; `skills.config` only toggles skills codex already found. So the
skills are listed in the developer message in the same shape codex uses for its own list — name,
description and the absolute `SKILL.md` to read — and the model reads the file with its shell,
which the sandbox allows. The same message names the tool prefix and the `rpc_port`, replacing
the paragraph the claude system prompt carries. It is byte-stable across the turns of one chat
(entries in `plugin_dirs` order, skills in sorted-glob order, the port fixed for the Neovim
session), because codex's prompt cache matches on a prefix like Anthropic's (#469).

The cost is that `-c` **replaces** a `developer_instructions` the user set in their own
`config.toml`, for vibing.nvim chats only. Accepted: codex has no additive key, and the
alternative — prepending the list to the user prompt — would carry it in every turn's message.

**A server name the key path cannot carry is refused, once.** The dotted path is split on `.` and
each segment taken literally, so `a.b` is unreachable and `"a.b"` is a different server. Such a
manifest is skipped with one warning per working directory, and `:VibingReloadCommands` clears
that memo along with `plugin_dirs`' cache.

**What does not travel.** `agents/` — codex has no subagent-definition format. `hooks/` and
`commands/` inside a plugin, which claude honours and vibing.nvim never listed. And nothing
about the way the CLI itself discovers skills changes: `.agents/skills` in the project is still
read, alongside what vibing.nvim adds.

**`build.sh` no longer registers the server with codex.** It used to run `codex mcp add
vibing-nvim`, a global entry in `config.toml` — the install `--plugin-dir` was adopted to avoid.
An entry an older build left behind is reported and left alone: the per-session override
deep-merges over it inside vibing.nvim, and a plain `codex` session outside Neovim may rely on it.

**Not verified here, and worth knowing.** Whether codex's PreToolUse hook fires for MCP tool
calls — and therefore whether the user's `ask`/`deny` lists gate a plugin's MCP tools on this
backend — could not be measured without a model turn. `developer_instructions` and
`default_tools_approval_mode` are not on `--strict-config`'s path in an ordinary chat, so a
future codex that renames either degrades silently: the skills vanish from the prompt, or MCP
calls start being cancelled. The silent-ignore of `--plugin-dir` has the same shape, and is why
`plugin_dirs` checks manifests itself.

## Slash Command Discovery

The `/` menu's skills and built-in commands come from the CLI itself, asked once per working
directory: `completion/cli_command_list.lua` spawns `claude` with `--input-format stream-json`,
writes a single `control_request` line of subtype `initialize`, reads the one-line
`control_response`, and kills the process. `completion/providers/skills.lua` shapes the answer
into completion items and caches it.

The point is that **built-in skills are inside the binary**. `/design`, `/dataviz`,
`/code-review`, `/loop`, `/run` and the rest are backed by no file anywhere, so the filesystem
scan this replaced could only ever offer a hand-written list — one in `skills.lua`, another in
`bin/list-commands.ts` — and both went stale on every CLI release. What is hand-maintained now is
`TERMINAL_ONLY_COMMANDS`, a **deny**list of commands that act on the interactive terminal session
(`/color`, `/usage`, `/rename`, ...). The inversion is the whole gain: a stale allowlist hides a
new skill, a stale denylist shows one extra entry.

**Measured against claude 2.1.231**, since none of the protocol is documented:

| Question                           | Answer                                                                   |
| ---------------------------------- | ------------------------------------------------------------------------ |
| Cost of the probe                  | None. No turn starts, so no request is made                              |
| Latency / size                     | ~800ms, 67 commands, one ~24KB line                                      |
| Does the CLI enumerate this?       | No `claude` subcommand lists skills; `--help` does not either            |
| `--max-turns 0` as a cheaper probe | Runs the turn anyway — measured at $0.16                                 |
| The `system`/`init` event instead  | Same list under `slash_commands`, but names only, and only mid-turn      |
| Plugin skills                      | Present and namespaced, when the same `--plugin-dir` flags are passed    |
| Disabled installed plugins         | Absent, which the filesystem scan got wrong in the other direction       |
| An unknown `subtype`               | `control_response` with `subtype: "error"`, no enumeration of valid ones |

Three of those rows are why the code looks the way it does.

**The response is checked layer by layer, and every stdout line is tried.** An undocumented
protocol that changes shape should produce no completions rather than a partial list, so a failed
check returns `nil` and the next `/` retries the probe. Reading only the first line would let
anything the CLI decides to print ahead of the answer discard it.

**`--strict-mcp-config` is passed even though the command list is identical without it.** The
process is killed the moment it answers; launching the user's MCP servers only to orphan them a
second later buys nothing.

**`--setting-sources` matches what a chat gets**, via `cli_command_builder.resolve_setting_sources`.
A narrower list on the probe than on the chat would hide project skills the chat can actually run.

The old route was `node dist/bin/list-commands.js`, which scanned `installed_plugins.json` and
each plugin's `skills/` directory. It is gone, and with it `bin/lib/plugin-loader.ts`,
`scripts/build.mjs` and the root `npm run build` step — the root bundle had nothing else in it.
Two behaviours changed with it, both toward what the CLI actually loads: an installed plugin the
user has disabled no longer appears (the scan's `enabledPlugins` check treated an all-disabled map
as "no filter"), and a skill is described by the CLI's own description rather than by a second
frontmatter reader.

## Startup Cost

`setup()` runs eagerly — the lazy.nvim example deliberately has no `cmd`/`event` trigger, because
the RPC server has to be listening and in the instance registry for Claude Code to find this
Neovim at all. So everything `setup()` does is on the user's startup path, and the module tree is
not what costs: measured on a warm cache, requiring every module `setup()` touches is ~9ms of it.
The cost is synchronous I/O.

Two pieces were therefore moved off that path, taking a measured ~32ms `setup()` to ~11ms:

- **Custom slash commands are scanned on first use, not at startup.**
  `custom_commands.scan()` globs `.claude/commands/*.md` for the project, the user, _and_ every
  installed Claude Code plugin, then `readfile`s each one whole — 76 files / ~417KB on one
  developer's machine, ~13ms, and it grows with every plugin installed. `commands.lua` owns the
  trigger now (`ensure_custom_loaded`), fired from `execute()` and `list_all()`, which are the
  only two readers of `M.custom_commands`. A Neovim that never opens a chat never pays it.

  The guard is set **before** the scan, not after, so a scan that finds nothing does not retry:
  `list_all()` is on the completion path and runs per keystroke.

  `:VibingReloadCommands` goes through `commands.reload_custom()` rather than clearing
  `custom_commands.lua`'s cache and re-running the loop itself. Assigning
  `commands.custom_commands = {}` from outside would empty the table while leaving the
  already-loaded flag set, and the commands would never come back.

- **`hook_cleanup.cleanup_stale_dirs()` is deferred to `vim.schedule`.** Hooks only run once a
  request is in flight, so nothing needs the sweep before the UI is up.

A scan moved to first use also reads `vim.fn.getcwd()` at first use, which is the more accurate
cwd for picking up a project's `.claude/commands/` anyway.
