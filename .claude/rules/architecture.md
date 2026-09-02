# Architecture

## Communication Flow

There is **no Node.js wrapper process**. vibing.nvim spawns the `claude` CLI directly with
`vim.system()` and parses its streaming JSON output:

```text
Neovim (Lua) ──vim.system()──> claude -p --output-format stream-json
     ▲                                    │
     │  stream-json lines (stdout)        │
     └────────────────────────────────────┘
     ▲
     │  hook callbacks (PreToolUse / StopFailure) over TCP
     └── bin/hooks/*.sh ──> RPC server (lua/vibing/infrastructure/rpc/)
```

The command is assembled in `cli_command_builder.lua`; the base flags are
`-p --output-format stream-json --verbose --include-partial-messages`, plus `--model`,
`--resume <session_id>` (`--fork-session` for forks), `--append-system-prompt`,
`--setting-sources`, permission flags, and `--settings .vibing/hook-settings.json`.

`cli_event_processor.lua` consumes the CLI's stream-json lines — `content_block_start`,
`content_block_delta` (`text_delta` / `input_json_delta`), `tool_use`, `tool_result`, `error`,
and `rate_limit_event` — and turns them into chunk/tool-display callbacks.

Everything that needs to call _back into_ Neovim mid-turn (permission decisions, approval UI,
`AskUserQuestion`, rate-limit reporting) goes through the RPC server rather than the stream.
`.vibing/hook-settings.json` (generated per cwd by `hooks/settings_generator.lua`) registers
`bin/hooks/pre-tool-use.sh` and `bin/hooks/stop-failure.sh`.

The PreToolUse hook is synchronous and blocks the tool call: it writes the hook payload to
`/tmp/vibing-hook-<port>/<request_id>.req`, sends a one-line JSON-RPC notification to the RPC port
with `nc`, then polls for `<request_id>.res` (up to 120s). It **fails closed** — if `nc` cannot
connect, or the response never arrives, the hook exits 2 and the tool is denied. `VIBING_HANDLE_ID`
is passed through so concurrent chats don't cross-wire each other's approval UI (see
`active_stream_registry.lua`). The comm directory path comes from
`infrastructure/rpc/comm_dir.lua` (the single source of truth shared by the handlers, the cleanup
routine and `bin/hooks/*.sh`). It is machine-wide shared state keyed by port, so it has two
escape hatches: `$VIBING_HOOK_COMM_DIR` overrides it outright (tests use this), and without a
listening port it falls back to a PID-suffixed path rather than a single shared `vibing-hook-0`.
The instance registry has the same treatment via `$VIBING_INSTANCES_DIR` (honoured by both
`rpc/registry.lua` and `claude-plugin/mcp-server/src/handlers/instances.ts`).

The `.res` file carries **three** decisions, not two, and the difference is the whole permission
contract with the CLI:

- **`deny`** — the hook exits 2 with the reason on stderr, which is how a deny rule's `message`
  reaches the model.
- **`allow`** — the hook prints the JSON verbatim on stdout, and the CLI skips its own permission
  gate. Note that exiting 0 in silence is **not** an approval: the CLI reads it as "no opinion".
- **`defer`** — vibing.nvim permits the call but leaves the CLI's gate, and with it the user's own
  `settings.json` rules, in charge. The hook exits 0 silently.

Only vibing-nvim's own MCP tools get `allow`; everything else vibing.nvim permits gets `defer`.
Granting everything would override the user's `settings.json` deny rules, which
`--setting-sources user,project,local` still pulls in.

Those MCP tools are the exception because `--allowedTools` cannot express them reliably: it takes
literal prefixes, and the plugin-scoped one is `mcp__plugin_<plugin>_<server>__`, built from
`claude-plugin/.claude-plugin/plugin.json`. `can_use_tool.is_vibing_nvim_mcp_tool` matches on the
suffix instead, so the grant survives a rename that `VIBING_NVIM_MCP_TOOL_PATTERNS` would not.
Before #564 every allowed call took the silent path, so under any mode but `bypassPermissions` the
CLI refused those tools while vibing.nvim's own log said "allow".

The match is on the name and nothing else, and that is worth stating plainly because an `allow`
skips the user's own `settings.json` rules. It requires the separator both registration styles put
before the server name (`_vibing-nvim__nvim_<tool>`), so a server merely _ending_ with the name
(`mcp__my-vibing-nvim__…`) does not match. A third-party server genuinely registered as
`vibing-nvim` and exposing `nvim_*` tools **would** be granted — nothing in a tool name says who
registered it. That needs an untrusted MCP server already in the user's own Claude Code config, so
it is accepted rather than solved.

`hook_cleanup.cleanup_stale_dirs()` (run at startup) treats a comm directory as stale only when
its owning Neovim is gone: it cross-checks `registry.list()`, which already filters to live PIDs,
so a concurrent instance's in-flight `.req`/`.res` files are never deleted.

**Backends:** `claude_cli.lua` (default), `codex_cli.lua`, `copilot_cli.lua` and `grok_cli.lua`
implement the adapter interface; `init.lua` picks one from `config.adapter`, and `send_message.lua` can switch
per request for non-claude agent types. Implementing the interface is not the same as feature
parity — `AskUserQuestion` is Claude-only, for reasons `features.md` records.

`lua/vibing/core/constants/agents.lua` is the single definition of what a backend is — module
path, export name, description, model candidates. `factory.lua`, `modes.lua` (`VALID_AGENTS`,
`VALID_MODELS`), `completion/providers/frontmatter.lua` and `infrastructure/init.lua` all derive
from it, so adding a backend is a one-file change (grok was added that way). It deliberately requires nothing, which
is what keeps the dependency one-way.

These are the seams that stop backend identity leaking into shared code. The rule they encode:
**a backend name belongs in that backend's own module, and shared code takes what it is handed.**
`bin/hooks/pre-tool-use.sh` is the one deliberate exception, and the last bullet says why.

- **Tool vocabulary.** Backends name their tools differently (codex calls an edit `apply_patch`,
  copilot uses `bash`/`view`/`create`/`edit`/`web_search`, grok `search_replace`/
  `run_terminal_command`). Each adapter owns a `<backend>_tool_vocabulary.lua` and passes it to
  `set_active_opts` as a generic `_tool_vocabulary`; `rpc/handlers/permission.lua` just calls
  `normalize_payload`, `to_canonical` and `normalize_input` when the module offers them. The
  handler contains no backend name.

  The three are separate because backends disagree at three different levels, and the order
  matters — each step feeds the next:
  1. `normalize_payload` — the hook payload's own key names. Claude sends
     `tool_name`/`tool_input`; grok sends `toolName`/`toolInput`. Read straight through, the
     handler sees a nil tool name, so the two steps below get nothing to work on, every rule
     misses, and the turn stalls until the hook fails closed. This must run **first**.
  2. `to_canonical` — the tool's name (`apply_patch` → `Edit`).
  3. `normalize_input` — where the path lives inside the input. Granular `paths` rules read
     `input.file_path`; grok sends `path`/`target_file`/`filePath`.

  All three shapes were captured from the real CLIs, not read off their docs.

- **No MCP on every backend.** Grok, like codex, registers no `chat_bufnr` and reaches no
  vibing-nvim MCP server, so `grok_command_builder` deliberately keeps `--rules` to the
  backend-agnostic conventions. Naming `nvim_ask_user_question` there would hand the model a tool
  it cannot call — see `features.md` → AskUserQuestion Support.

- **Grok's hooks need a git repository.** `grok_settings_generator.lua` writes
  `<cwd>/.grok/hooks/` and marks the cwd trusted in `<$GROK_HOME|~/.grok>/trusted_folders.toml`,
  but grok discovers project hooks only inside a git repo (verified with `grok inspect`: the
  `project` entry appears under "Hooks" after `git init` and is absent before). Outside one the
  file is written and never read, which would silently allow every tool, so `ensure()` warns
  once per cwd instead. `$GROK_HOME` is grok's own documented override and is honoured — which is
  also the seam the specs use, since folder trust cascades to subdirectories and never expires.

- **Copilot injects its hook as a plugin.** Copilot has no per-run hook flag, and the two places
  it reads hooks from are both off limits: `~/.copilot/` is the user's own config and
  `.github/hooks/` is their repository. But `copilot --plugin-dir <dir>` loads a plugin for that
  run only, and a plugin may contribute hooks — so `copilot_settings_generator.lua` writes a
  throwaway plugin to `<cwd>/.vibing/copilot-plugin/` and points `--plugin-dir` at it. The hooks
  are inlined in `plugin.json` (one file, no sibling `hooks.json`), which works only as a bare
  event map: the `{"version": 1, "hooks": …}` envelope a standalone hooks file requires is
  silently ignored when inlined — both forms were run against the CLI.
  That is what makes `dynamic_permissions` true for copilot. Unlike grok's, it does **not** need a
  git repository (checked by running copilot in a non-git cwd and reading its own log).

  Three things about copilot's hook contract were captured from copilot 1.0.78 rather than read
  off its docs, and each one silently disables the gate if got wrong:
  1. **Its schema is not Claude's.** The event is lowercase `preToolUse`, the command goes under
     `bash`, and the timeout is `timeoutSec`. A matcher in a camelCase event is compiled as a
     regex, so Claude's `*` is rejected — `~/.copilot/logs` reports "Invalid matcher regex … hook
     will be skipped" and every tool runs unchecked. The generated file omits the matcher.
  2. **It reads a flat decision.** `{"permissionDecision":…}` on stdout; the
     `{"hookSpecificOutput":{…}}` wrapper is ignored, and a nested deny let the tool run. Exit 2
     denies too, but the model is told only "hook exited with code 2" — stderr is dropped, where
     Claude uses it to carry the reason. So `pre-tool-use.sh` takes a `copilot` argument and
     unwraps the response instead of re-encoding it (a reason containing a quote survives).
  3. **A hook timeout fails _open_.** Every non-zero exit fails closed, but a hook that outlives
     `timeoutSec` is ignored and the tool proceeds. The generated `timeoutSec` therefore stays
     well above the ~120s that `pre-tool-use.sh` waits before denying.

  The payload differs too — `toolName` with `toolArgs` as a JSON _string_ — which
  `copilot_tool_vocabulary.normalize_payload` handles, the same seam grok uses. Every name in that
  table except `powershell` and `rg` was read off a real payload; those two come from GitHub's
  hooks reference and are kept because a missing alias lets a deny rule fall open, while a
  never-sent one is inert.

  A subagent's own tool calls reach this hook as well, under their own names (`task` fires, then
  the `bash` the subagent runs) — so the gate covers delegated work, not just the top-level turn.

  **Why the backend name is in the shared script**, against the rule above: what varies is not
  only the JSON shape but the deny _signalling convention_ — Claude denies with exit 2 + stderr,
  copilot with exit 0 + stdout. That is shell semantics, so it lives in the shell. The
  alternatives are worse: a second script would duplicate the ~90 lines that are the security
  half of this one (comm dir, atomic `.req` rename, `nc` fail-closed, the 120s poll, the timeout
  deny), and a fail-closed protocol that exists twice is one that drifts into failing open;
  writing the decision in the backend's own format from `permission.lua` would move process
  control into Lua and force the handler — which deliberately knows no backend name — to pick an
  encoder, including on the fallback deny path where no `active_opts` resolve. Passing no
  argument selects Claude's convention, which is what the other three backends do.

  The gate is skipped in two cases, both by `copilot_cli.lua` rather than the generator:
  `bypassPermissions` (the mode asked for no gate) and `lightweight` (`core/types.lua` obliges
  every adapter to register no hooks for utility calls). And installing it is allowed to fail:
  the generator runs under `pcall`, and a failure warns and falls back to the static
  `--deny-tool` flags rather than taking the turn down.

## Module Structure

The tree is layered (`domain` / `application` / `infrastructure` / `presentation`), not the flat
`actions/` + `ui/` layout used before v4.

**Core:**

- `lua/vibing/init.lua` - Entry point, command registration, adapter selection
- `lua/vibing/config.lua` - Configuration defaults with type annotations
- `lua/vibing/core/constants/` - `agents.lua` (backend registry), `tools.lua` (VALID_TOOLS),
  `modes.lua`, `worktree.lua`
- `lua/vibing/core/utils/` - timestamp, language, git, git_snapshot, rate_limit, request_diff, ...

**Adapter (`lua/vibing/infrastructure/adapter/`):**

- `base.lua` - Abstract adapter interface
- `claude_cli.lua` / `codex_cli.lua` / `copilot_cli.lua` / `grok_cli.lua` - Backend adapters
  (`new()` and `stream()`; everything else comes from `cli_runtime`)
- `modules/cli_runtime.lua` - `execute`/`cancel`/`supports` + session delegations, installed onto
  each adapter class; plus `new_handle_id`, `kill_tree`, `spawn` (the guarded `vim.system` call —
  a spawn that raises leaves no process, so the exit handler never cleans up), and
  `report_build_failure`
- `modules/command_builder_common.lua` - Language resolution, the response-language sentence, the
  `@file:` context prefix, and cached binary lookup — the backend-agnostic half of argv building
- `modules/cli_command_builder.lua` - Claude CLI argv construction (flags, system prompt)
- `modules/cli_event_processor.lua` - stream-json → chunk/tool events
- `modules/codex_command_builder.lua` / `modules/codex_event_processor.lua` - Codex equivalents
- `modules/non_claude_model.lua` - Model resolution for codex/copilot/grok
- `modules/<backend>_tool_vocabulary.lua` - Native tool name <-> canonical name, per backend
- `modules/session_manager.lua`, `modules/active_stream_registry.lua` - Session/handle tracking

**What a new backend still has to write** is `new()` and `stream()`. `stream()` stayed
per-adapter deliberately: its variation points — which settings generator runs before the build,
how many arguments the command builder takes, whether a `chat_bufnr` or a tool vocabulary gets
registered, whether stderr needs filtering — outnumber its shared lines, and the four adapters
genuinely disagree on the child environment. `cli_runtime` covers the pieces inside it that do
repeat.

Two behaviours were unified rather than parameterised while extracting them, because the split
was drift rather than intent. `cancel()` now kills the CLI's descendants before the parent on every
backend; killing only the parent lets shells or MCP servers spawned by tools keep the stdout pipe
open, and `vim.system()`'s exit handler waits for that pipe to close. And `execute()` now cancels
a run that outlives its timeout instead of returning and leaving the process alive; only grok did
that. `cli_runtime_spec.lua` runs both over every backend.

The descendant walk is asynchronous (`vim.system`) rather than blocking (`vim.fn.system`), because
`cancel()` can be reached from a `vim.schedule` callback and should not stall the main loop there.
The shell script walks descendants with `pgrep -P`, kills them deepest-first, then kills the
parent; `handle:kill(9)` is only a fallback chained to the shell's `on_exit`, preserving that
ordering. Separately, `cancel()` calls the adapter's wrapped `on_done` path immediately after
starting termination, so registry cleanup, permission-opt cleanup, timers, and chat UI state do
not depend on the process exit callback ever arriving.

**Chat (presentation + application):**

- `presentation/chat/buffer.lua`, `view.lua`, `controller.lua` - Chat buffer and window
- `presentation/chat/modules/` - renderer, streaming_handler, frontmatter_handler, file_manager,
  approval_parser, keymap_handler, ...
- `application/chat/send_message.lua` - Request orchestration (opts, callbacks, diffs)
- `application/chat/use_cases/fork.lua` - Chat fork
- `application/chat/auto_resume.lua` - Usage-limit auto-resume scheduler

**RPC / hooks:**

- `infrastructure/rpc/server.lua` - Async TCP server queried by hooks and the MCP server
- `infrastructure/rpc/handlers/permission.lua` - PreToolUse decisions, approval UI,
  `ask_user_question`
- `infrastructure/rpc/handlers/rate_limit.lua` - StopFailure receiver
- `infrastructure/hooks/settings_generator.lua` - Writes `.vibing/hook-settings.json`

**Context System:**

- `application/context/manager.lua` - Context manager (manual + auto from open buffers)
- `infrastructure/context/collector.lua` - Collects `@file:path` formatted contexts

**UI:**

- `ui/permission_builder.lua` - Interactive permission configuration UI
- `ui/patch_viewer/`, `ui/command_picker.lua`, `ui/chat_deletion_picker.lua`

## Key Entry Points

Quick reference for commonly edited files:

```text
Lua Plugin:
- lua/vibing/init.lua                    - Plugin initialization and commands
- lua/vibing/config.lua                  - Configuration schema and defaults
- lua/vibing/infrastructure/adapter/claude_cli.lua                 - Claude CLI adapter
- lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua - CLI argv / system prompt
- lua/vibing/presentation/chat/buffer.lua                          - Chat buffer implementation
- lua/vibing/application/chat/send_message.lua                     - Request orchestration

Node.js side (no agent wrapper — only these):
- bin/hooks/pre-tool-use.sh    - PreToolUse hook → RPC
- bin/hooks/stop-failure.sh    - StopFailure hook → RPC
- claude-plugin/mcp-server/src/index.ts      - MCP server entry point
- claude-plugin/mcp-server/src/tools/        - MCP tool implementations (buffer, lsp, window, chat)

Tests:
- tests/lua/**/*_spec.lua      - Lua tests (plenary.nvim)
- tests/*_spec.lua             - Older top-level Lua specs
- tests/*.test.mjs             - Node.js tests
- tests/e2e/*.spec.lua         - E2E tests against a spawned Neovim instance
```

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

## Session Persistence

Chat files are saved as Markdown with YAML frontmatter:

```yaml
---
vibing.nvim: true
session_id: <cli-session-id>
created_at: 2024-01-01T12:00:00
orchestrated: # Optional: chats this one drives (see "Multi-Agent Orchestration")
  - .vibing/chat/worker-auth.md
orchestrated_by: # Optional: the chat driving this one
  - .vibing/chat/orchestrator.md
working_dir: .vibing/worktrees/fix-auth-session # Optional: relative path from git root for working directory
model: sonnet # sonnet, opus, haiku, or fable (from config.agent.default_model)
effort: xhigh # Optional: low, medium, high, xhigh, max (from config.agent.default_effort)
permission_mode: acceptEdits # default, acceptEdits, bypassPermissions, plan, dontAsk, or auto
permissions_allow:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
permissions_deny:
  - Bash
language: ja # Optional: default language for AI responses
---
```

When reopening a saved chat (`:VibingChat <file>` or `:e`), the session resumes via the stored
`session_id`. The `model` field is automatically populated from
`config.agent.default_model` on chat creation, and can be changed
via `/model` slash command.

`effort` is the second cost/quality knob, passed to the CLI as `--effort`. Unlike `model` it is
**omitted unless configured**: with no `agent.default_effort` vibing.nvim passes no flag and the
CLI applies its own default, which Anthropic tunes over time — pinning a level here would freeze
it. Set it per chat with `/effort`. Lightweight calls (title generation, `/summarize`,
`:VibingSummarize`, daily summary) use `agent.utility_effort` (default `low`) instead. It does
**not** pair with a cheap model: `utility_model` defaults to `sonnet`, because those calls
summarize a noisy chat transcript and haiku measurably picks the wrong subject. Low effort on a
capable model is the trade actually being made here. An unrecognised level is dropped with a
warning rather than passed through: the CLI accepts unknown levels silently and then ignores them.

**Lightweight calls are restricted differently per backend, because the CLIs differ in kind.**
Claude removes the tools outright with `--tools ""`. Codex cannot: probing its config schema with
`--strict-config` (which rejects unknown fields) against codex 0.147 shows `tools.shell`,
`tools.apply_patch`, `tools.view_image`, `tools.plan_tool` and `tools.mcp` are all unknown fields,
and `tools.web_search` is the only tool toggle that exists. So `codex_command_builder` fences the
call in instead — `sandbox_mode="read-only"`, `tools.web_search=false`, `approval_policy="never"`,
`project_doc_max_bytes=0`, plus the flags `--ignore-user-config --strict-config` — and
`codex_cli.lua` skips hook registration, matching `claude_cli.lua`. `project_doc_max_bytes=0` and
`--ignore-user-config` are codex's answers to claude's `--setting-sources ""` and
`--strict-mcp-config`/`--mcp-config`: without them a utility call still read `AGENTS.md` and still
reached the user's MCP servers. `--strict-config` is not a fence of its own — it is what keeps the
others from lapsing unnoticed.

**`-c mcp_servers={}` used to stand in for that and did nothing**, which is what #574 was about.
`-c` _deep-merges_ into `config.toml`, so an empty table adds no keys and removes none: measured
against codex 0.147, `codex mcp list -c 'mcp_servers={}'` still lists every configured server, and
under `codex exec` a server whose command touches a file was still launched and still wrote it.
That last part makes it a boundary rather than a preference — codex spawns MCP servers itself, so
the process runs **outside** the read-only sandbox. No narrower switch exists (`mcp.enabled`,
`tools.mcp`, `features.mcp`, `mcp_enabled`, `disable_mcp` are all unknown fields; `mcp_servers=false`
is a type error), and per-server `mcp_servers.<name>.enabled=false` works but needs a name list
that goes stale the moment a server is added — silently, which is the failure mode being fixed.
`--ignore-user-config` is therefore accepted along with its known cost: it also drops
`model_provider`, so a user on a custom provider gets utility calls against the default OpenAI
endpoint. Auth is unaffected; codex reads it from `CODEX_HOME` either way.

`--ignore-user-config` does **not** cover `project_doc_max_bytes`. `AGENTS.md` is discovered from
the cwd, not from `config.toml`, so dropping the user config only restores the key's 32768-byte
default. Verified with `codex debug prompt-input`, which renders the model-visible prompt without
calling the model: a marker line in `AGENTS.md` is present without the override and absent with it.

**`--strict-config` is what stops the rest of that list from lapsing in silence.** Codex ignores
unknown `-c` keys, so the day it renames or drops one, the fence would come off with no error and
no warning — and unlike the degradation `rate_limit.lua` tolerates, what is lost here is a safety
boundary whose absence is unobservable. With the flag, the utility call fails loudly instead. It is
only safe **paired with `--ignore-user-config`**: on its own it also strictifies the user's
`config.toml`, so one unrecognised field of their own would break every title generation — which is
what made #571 reject the flag. With the user config unread it validates our overrides and nothing
else. Both flags have existed since at least codex 0.140 and are accepted on `codex exec resume`
too, so unlike `-s` neither is lost on the `/summarize` path.

`read-only` blocks writes **and** network, verified by running commands under `codex sandbox`
rather than read off the docs: a write reports `Operation not permitted` and `curl` returns
`000` where the same request outside the sandbox returns `200`. That matters because the shell
tool itself cannot be removed, so the sandbox is the only thing closing the exfiltration path
a prompt injection in the summarized transcript would otherwise have.

Three details there are not interchangeable. The restrictions are `-c` overrides rather than the
`-s` flag because `/summarize` passes a session id and `codex exec resume` does not accept `-s`. The
restriction ignores `permission_mode` entirely, `bypassPermissions` included: the user put the
_chat_ in that mode, and a title generated behind their back is not the call they made. And
`utility_model` still goes through the Claude-name filter, so its `sonnet` default becomes no
`-m` at all rather than a model codex would reject.

**Copilot can remove the tools outright, and does it in one flag.** `--available-tools` is the
filter deciding "which tools the model can see" (`copilot help permissions`), so a list naming
nothing leaves nothing. Measured against copilot 1.0.78 by counting tool schemas in
`--log-level debug` output: an ordinary run offers 62 tools, `--available-tools=view` offers 1,
and `--available-tools=__vibing_no_tools__` offers 0 — with the turn still completing normally
(`toolRequests: []`, exit 0). That count includes the user's MCP tools, so the one flag also
covers what claude needs `--strict-mcp-config` for; the MCP servers are still spawned, but expose
nothing. `--no-custom-instructions` is the `--setting-sources ""` half, verified by planting a
sentinel string in `AGENTS.md` and watching it reach the prompt twice without the flag and not at
all with it. Nothing to skip on the hook side: `copilot_cli` registers none at all.

The sentinel has to be a name, not an empty string. `--available-tools=` parses as an empty list
and copilot ignores it, leaving all 62 tools — so the flag reads as working while doing nothing.

**Grok fails open on exactly that trick, which is why it does the opposite.** Its `--tools` is an
allowlist, but an entry it cannot map to a real tool id makes it discard the whole restriction:
`--debug-file` on grok 0.2.101 records
`tools allowlist had unmappable entries; keeping full grok toolset` for `--tools "none"`, and
`--tools ""` is ignored the same way copilot's empty list is. So `grok_command_builder` names a
real tool — `todo_write`, the only built-in reaching no file, shell or network — and the run logs
`tools allowlist applied` with the toolset down from 26 to 3. `--permission-mode dontAsk` stands
in for codex's `approval_policy="never"`.

**Skipping the hook does not mean grok has no hook**, and that difference bites. Claude and codex
register one per invocation (`--settings <path>`, `-c hooks.pre_tool_use=…`), so omitting the flag
genuinely leaves the run hookless. Grok discovers `<cwd>/.grok/hooks/` instead, which
`GrokSettingsGenerator.ensure` writes once per cwd and nothing ever removes — so `grok_cli`
skipping `ensure` for a lightweight call only skips _rewriting_ it. Any project that has had one
ordinary grok chat still has the hook on disk, and a utility call is by definition something that
happens after a chat.

**Copilot does not have grok's problem**, despite also writing its hook into the project tree. The
generated plugin under `<cwd>/.vibing/copilot-plugin/` is reachable only through `--plugin-dir`,
which the lightweight branch never emits — copilot auto-discovers hooks from `~/.copilot/hooks/`,
`.github/hooks/`, its policy dirs and `settings.json`, and vibing.nvim writes none of those. So a
leftover plugin from an earlier chat is inert, and skipping generation really does leave the run
hookless, the way it does for claude and codex.

That is why `todo_write` had to be added to `grok_tool_vocabulary`. It is claude's `TodoWrite`
under another name; unmapped, the raw name reached `can_use_tool`, missed the `INTERNAL_TOOLS`
always-allow list, matched nothing in the default allow list and resolved to `ask` — which
`cancel_and_deny` serves by killing the CLI process _before_ checking for an approval UI. A
lightweight call registers none, so a title generation would have died silently on the one tool
its own allowlist leaves it. Deleting the hook file instead was rejected: the cwd is shared with
every concurrent chat, which still needs it.

**Grok is the one backend that cannot keep the whole `lightweight` bargain,** and that is a
property of its CLI rather than something left undone here. `--tools` filters built-ins only —
MCP tools are added on top regardless (the advertised count stays ~254 higher either way) and
grok 0.2.101 has no per-run flag to disable MCP servers, so the builder can only deny their
_execution_ with `--deny "MCPTool(*)"`, in the `MCPTool(server__tool)` form grok's rules require.

That wildcard is measured, not assumed, because a rule grok does not recognise is dropped in
silence — `grok inspect`'s permission count goes 1 → 2 for `MCPTool(*)` loaded from a
`.grok/config.toml` but stays at 1 for an invented kind, which it still reports as "0 skipped".
Enforcement was then checked through the flag itself against a real MCP call: same prompt, same
flags, `--deny` the only difference. Without it the model reports the tool called successfully;
with it, "denied by a permission policy", and the debug log records
`deny rule matched (enforced before YOLO) tool="mcp:vibing-nvim__nvim_list_instances"`. Both runs
passed `--always-approve`, so "before YOLO" is where the `deny` > `ask` > `allow` precedence gets
confirmed too — which is what makes this not redundant with `dontAsk`.
Project instructions have no escape hatch at all: grok reads `AGENTS.md`/`CLAUDE.md` from the repo
and the home directory, and the only switches (`[compat.claude]`, `[mcp_servers]`) are persistent
config, not per-invocation. `--sandbox read-only` was considered and rejected — grok's own docs
say its network blocking is a no-op on macOS, and resuming a session under a sandbox profile is
constrained, which `/summarize` always is.

The model half of that lives in `modules/non_claude_model.lua`, shared by codex, copilot and grok.
It was three byte-identical private copies before, and #537 was filed against codex alone — so
teaching one copy about `lightweight` would have left the same bug live on the other two, with
nothing marking them stale. The restriction half stays per-backend on purpose: claude _removes_
tools with `--tools ""`, codex can only fence them, and no shared vocabulary spans that.
`core/types.lua` states the obligation each adapter owes for `lightweight` — no tools, no project
config, no hooks, `utility_model` — rather than the mechanism any one of them uses.

**The `model_provider` that `--ignore-user-config` drops is announced rather than left to be
discovered** (#587). `codex_provider_notice.lua` warns once per Neovim session when the configured
provider is not codex's own `openai` default. `codex_cli.lua` triggers it on `--ignore-user-config`
actually being in the argv it just built, not on `opts.lightweight` alone: the builder documents
that flag as a stand-in for a narrower switch codex does not have yet, so reading the built command
is what makes the warning disarm itself the day the flag stops being used, rather than going on
describing a loss that no longer happens. `lightweight` still guards the scan because the prompt is
the last element of the argv, and a message consisting of exactly that flag would otherwise match.

It warns and does not repair, because codex will hand over the provider's _name_ and not its
_definition_: `codex doctor --json` reports the resolved provider at
`checks["config.load"].details["model provider"]`, but nothing reports the
`[model_providers.<name>]` table — not `doctor`, and not the app-server protocol, whose
`ConfigReadResponse.Config` carries `model_provider` as a bare string and no provider map at all
(`codex app-server generate-json-schema --experimental`). Re-injecting the provider would still
mean hand-parsing `config.toml`, which is why #587's option 2 was not taken.

Asking codex is the whole point: the name comes back **resolved**, by codex's own config loader,
so there is no TOML parsing and none of the false positives (an inactive profile section) or false
negatives (a profile) that kept the warning out of #582. Three properties of the probe are
load-bearing:

- **The exit status says nothing.** `codex doctor --json` exits 1 whenever any check fails, and a
  missing login alone is enough — it exits 1 even on a config that loaded cleanly. Only
  `checks["config.load"].status` answers the question, and stdout is valid JSON either way.
- **The key is `"model provider"`, with a space.** Captured from codex 0.147 into
  `tests/fixtures/codex_doctor.json` rather than read off a schema.
- **Unreadable means silent.** Every parse failure returns nil and nothing is said, because an
  unreliable warning is worse than none — its silence gets read as "you are fine".

It runs on the first lightweight call rather than at `setup()` because `doctor` makes one
reachability request to the active provider's endpoint; it is asynchronous and nothing waits for
it. `agent.codex_provider_notice.enabled` turns the whole thing off, probe included, and is the
one toggle of this shape that **defaults to `true`** — `subagent`, `auto_resume_on_limit` and
`dap` all default to `false` because they spend tokens or run unattended, and this spends none. A
warning about a change the user cannot otherwise see fails at its only job if it is off until
asked for. Absent config reads as enabled, so a hand-built config table does not silently lose it. The `profile = "x"` config key that #582 named as a false-negative route is moot from codex
0.147, which rejects it outright (`legacy profile = "x" config is no longer supported`); the
surviving route is the `-p/--profile` flag, which vibing.nvim passes to neither `codex exec` nor
the probe, so the two resolve identically.

Configured permissions are recorded in frontmatter for
transparency and auditability. The optional `language` field ensures consistent AI response language
across sessions.

Note the singular `permission_mode`: that is the key `send_message.lua` actually reads, the key
completion offers, and the key the serializer orders. The legacy plural `permissions_mode` is
migrated to the singular form on parse (`infrastructure/storage/frontmatter.lua`) so old chat
files keep working, but it is no longer completed and should not be written.

**Working directory persistence:** The `working_dir` field stores the working directory as a relative
path from git root (e.g., `.vibing/worktrees/<branch>`). When a chat is reopened, the agent
runs in this directory, and it is also the worktree that per-request diff snapshots use. This
ensures consistent file operations across sessions, even when using a worktree or a custom
directory.

`Git.resolve_working_dir` **bounds it to the git root**, symmetrically with `get_relative_path`:
a value resolving outside (`../../etc`, or a symlink inside the repo pointing out of it) is
warned about once and treated as unset, so the chat falls back to Neovim's own cwd rather than
failing to open. Returning `nil` rather than substituting the git root is what keeps the meaning
single — `nil` already means "no chat-specific cwd" at every call site — and is what lets a
caller that validates the directory (`create_chat.lua`) reject an out-of-bounds request outright
instead of silently succeeding at the root.

Two things about that check are not interchangeable, both verified against the real functions
rather than read off the docs. `vim.fn.fnamemodify(path, ":p")` does **not** collapse `..` in a
path that is already absolute (`/a/b/../c` comes back unchanged), so it cannot do this job;
`vim.fn.resolve()` collapses `..` _and_ follows symlinks, and unlike `vim.uv.fs_realpath()` it
works on a path that does not exist yet. And the comparison is between physical paths on both
sides: `git rev-parse --show-toplevel` always reports the symlink-resolved path, which on macOS
is `/private/tmp/...` for anything under `/tmp`, so comparing it against an unresolved candidate
would reject directories that are genuinely inside. The boundary is decided on the resolved
form, but the string handed back is the plain `git_root .. "/" .. working_dir` — a chat whose
`working_dir` goes through a symlink keeps seeing the path it wrote.

## Per-Request Diffs

Each turn's `### Modified Files` list and its `.vibing/patches/*.patch` come from **two git tree
snapshots of the working tree**, taken before and after the turn and compared with `git diff`
(`core/utils/git_snapshot.lua`). That is the main path, not the only one: a read-only turn takes
no snapshot at all, and the two cases in the table below fall back to `request_diff.lua`.

The point of that shape is what it does _not_ need to know: which tool made the change. The
mechanism it replaced (`request_diff.lua`) backed up the file named in a Write/Edit tool's
arguments, so `sed -i`, `mv`, a formatter, or anything else run through Bash produced no diff
section at all — the change simply did not exist as far as the chat was concerned. This is #625.

**The baseline is lazy, and that is what keeps it cheap.** It is taken at the PreToolUse hook for
the first tool of the turn that could write, not at the start of the request, so a read-only turn
takes no snapshot. It is not literally free of git: `send_message` resolves `_worktree_root` when
it builds the request's opts, which is one `rev-parse --show-toplevel`. That is cached per working
directory, so inside a repository it costs one process the first time a chat sends from a given
directory and nothing after. **Only successes are cached**, so a working directory that is not in a
repository re-resolves on every send — deliberate, since remembering "not a repo" would leave a
directory that later becomes one (or gains a worktree) permanently misjudged, and the miss is a
`rev-parse` that fails fast. The trigger is an **exclusion** list (`Read`/`Glob`/`Grep`/
`WebFetch`/`WebSearch` plus the side-effect-free `INTERNAL_TOOLS`), not an allow list: an MCP tool
whose name says nothing about its behaviour has to count as a writer, and the cost of guessing
wrong that way is one wasted snapshot rather than a silently missing diff. Note that
`INTERNAL_TOOLS` is _not_ a read-only list — it deliberately carries `NotebookEdit`, `Agent`/`Task`
and `EnterWorktree` — so those are put back on the mutating side by name.

**The user's index is never touched.** `git add -A` runs against a copy of the real index handed
over as `GIT_INDEX_FILE`, so it takes a `<tmp>.lock` rather than `.git/index.lock` and cannot
collide with a `git commit` the user runs mid-turn. The copy exists only to inherit the stat
cache, and that is worth more than it looks: measured on an 80k-file tree, a snapshot takes 63ms
with the copied index and 210ms starting from an empty one, so a failed copy means a slower first
snapshot rather than a broken one. `commit-tree` then wraps the tree, with
`HEAD` as parent when there is one — a repository with no commits at all works, parentless.

Three details are not interchangeable:

- **The git calls block the main loop** (`vim.system():wait()`) — the baseline inside the
  synchronous PreToolUse hook, the diff at response time. Measured at 20ms per `git add -A` on a
  9k-file tree and 63ms on an 80k one, which is why it is accepted; but the cost scales with the
  tree, so a very large monorepo or a worktree on a network filesystem is where this would be felt
  first and is worth revisiting if anyone reports it.
- **Every git call takes the same `cwd`,** normalized through `rev-parse --show-toplevel` first.
  `get_cwd()` can point at a subdirectory, and in a linked worktree the whole scope — which index,
  which refs — is decided by that directory. `rev-parse --git-path index` is what finds the index
  at all, since a worktree's lives under `.git/worktrees/<name>/`.
- **`refs/worktree/vibing/<handle>` is a per-worktree namespace** (git 2.23+), so removing a
  worktree takes its leftover refs with it instead of leaving them in the common ref store. The
  ref is only a guard against a `git gc` landing mid-turn, so an `update-ref` that fails (an older
  git) is swallowed and the turn proceeds — freshly written objects are not pruned by gc's
  two-week default either way. `clear()` deletes the ref and nothing else: **no `git gc`**, since
  the unreferenced objects are collected by the user's own `gc --auto` in due course.
- **Leftover refs are swept per worktree, not once at startup**, and that is a consequence of the
  namespace above rather than belt-and-braces: verified against git, a `for-each-ref` in the main
  worktree does not enumerate a linked worktree's `refs/worktree/` at all (they live under
  `.git/worktrees/<name>/refs/`). So `M.sweep()` at startup only reaches Neovim's own cwd, and a
  crash during a turn in `.vibing/worktrees/<branch>/` — the project's normal way of working —
  would leave its ref there forever. `ensure_baseline` therefore sweeps a root the first time it
  takes a baseline in it, deleting only refs older than the session TTL. Only the first of its two
  guards is exact: the ordering rules out a live ref of _this_ process, since the sweep runs on a
  root's _first_ baseline, when no session on that root exists yet. Against another Neovim the pair
  is best-effort — the registry can under-match (it knows an instance's own cwd, not which worktree
  its chats run in) and a turn can outlive the TTL, which is precisely what `sweep_stale` had to
  stop assuming. What is lost when they both miss is one gc guard, not the diff.
- **Untracked files that the turn never touched are still hashed into the object database**, since
  that is what `git add -A` does and what makes a new file show up as a diff at all. They are
  written to the local `.git/objects` only, become unreachable the moment `clear()` drops the ref,
  and are never pushed — `git push` sends what is reachable from the refs being pushed, and a
  snapshot commit is an ancestor of no branch. Accepted rather than solved: excluding untracked
  files would cost new-file detection, which is half the point.
- **`-c core.quotePath=false`** on both diff calls, or a non-ASCII path comes back octal-escaped
  and the file list stops matching the file on disk.
- **`-M` on both diff calls too**, not just the patch. Without it on `--name-only`, a user who has
  set `diff.renames=false` gets a pure rename split two ways — one `rename` entry in the patch, two
  entries (the delete and the add) in the file list — and the vanished path is then handed to
  `BufferReload`. Reproduced against git before fixing.
- **The file list is a second `git diff --name-only`, not something parsed out of the patch.**
  Reading `+++ b/…` misses three kinds of change outright, because git emits no such line for
  them — a binary file (`GIT binary patch`), a pure rename (`rename from`/`rename to`), or a
  mode-only change (`old mode`/`new mode`); reading the `diff --git a/X b/Y` header instead cannot
  split a path containing a space, which is the weakness `ui/patch_viewer/parser.lua`'s regex
  already has. Both failures are the silent-omission shape this whole mechanism exists to remove.
  The duplication is also small: this compares two **tree objects**, not the worktree, and
  `--name-only` generates no hunks — measured on a 9k-file repository at 3ms for the patch and 2ms
  here, against 20ms per `git add -A` (twice a turn). A turn whose patch came back empty skips it
  entirely, since an empty patch already answers "no files changed".
- **`.vibing/` is excluded by pathspec**, not left to `.gitignore`. It holds the chat files and the
  patches themselves and changes during the turn, so for anyone who has not git-ignored it every
  turn would list the conversation log as its own output and put the whole transcript in the patch.
  The removed mote integration excluded the same directory through `.moteignore`. The exclusion is
  on the diff calls (where it matters) and on `git add -A` (where it saves hashing).

**The two baselines are taken under separate `pcall`s** (`permission._capture_baselines`). Sharing
one would let the fallback take the main path down with it: `request_diff.capture` builds its
backup directory through `Fs.ensure_dir`, which re-raises everything that is not the
concurrent-creation race, so a throw there would skip `ensure_baseline` and leave a turn with
neither baseline. Both stay guarded, because neither may break the permission decision.

**When both come up empty, the turn says so.** A snapshot that could not be read plus no tool
event at all is indistinguishable from "nothing changed" — and for a turn that worked only through
Bash, that is precisely the silent loss this mechanism exists to remove. `_handle_response` warns
in that one case rather than appending an empty section.

**The fallback's backups are dropped only once the snapshot path has actually produced output.**
`generate` therefore reports "could not tell" separately from "nothing changed" — a second
snapshot or diff that fails (a worktree removed mid-turn, a permission or disk error) returns
`ok = false`, and `_handle_response` routes to `request_diff` instead, whose backups are still
there. Clearing them first would mean a failure at that one point silently produced a turn with no
diff and no warning, which is the failure this whole mechanism exists to remove.

**`request_diff.lua` stays** as the fallback for the cases a snapshot cannot serve, decided in
`_handle_response`:

| Condition                                        | Path                      |
| ------------------------------------------------ | ------------------------- |
| `working_dir` is not inside a git repository     | `request_diff`            |
| Another turn's write window overlapped this one  | `request_diff`            |
| The snapshot was attempted and could not be read | `request_diff`, else warn |
| Otherwise                                        | `git_snapshot`            |

The third row is the recovery path rather than a routing decision: the snapshot was the right
mechanism and simply failed, so the turn takes whatever the fallback backed up — and when that is
empty too (a Bash-only turn), it warns instead of rendering as a turn that changed nothing.

The second row is the one worth stating plainly: the tree is shared state, and nothing in it
records _whose_ `sed -i` ran. A snapshot diff spanning a window in which a second chat was also
editing the same worktree would report that chat's work as this turn's. Missing the Bash-driven
changes of one overlapping turn is the less wrong answer.

**The overlap has to be recorded when the baseline is taken, not asked about at response time**,
and getting that wrong makes the guard protect the wrong side. A point-in-time
`find_other_active_for_worktree` at response time is only answered honestly for the turn that
finishes _first_ — by the time the second one asks, the first has already unregistered, so it reads
"no overlap" and takes the snapshot path. But its window (its own baseline → its own diff) is
precisely the one that contains the other turn's changes, so the misattribution lands on exactly
the turn the check waved through. It is structural, not a race: it happens on every overlap.

So `ensure_baseline` walks the sessions already open on the same root, marks itself and marks each
of them (`had_overlap`). A session lives from its baseline to its `clear()`, which is the interval
the diff covers, so two open sessions on one root _are_ two overlapping windows. Marking both is
what makes the fallback symmetric — the second turn still knows, long after the first has gone.

`ActiveStreamRegistry.find_other_active_for_worktree` is kept as the second signal, for a stream
that is writing without a session of its own to be seen through (a `write-tree` that failed on a
conflicted index, say). It excludes by **handle_id**, not by `chat_bufnr` the way
`find_other_active_for_session` does — codex and grok register no `chat_bufnr` (see `features.md`),
so two of those would compare `nil` against `nil` and never see each other.

**Both overlap signals are process-local, so two Neovim instances on one worktree are out of
scope.** `sessions` and `ActiveStreamRegistry` are module tables, so a chat running in a second
Neovim is invisible to the first: both would take the snapshot path and each would report the
other's changes as its own — **all** of them, not just the Bash-driven ones, since a tree diff
carries every change made in the window whatever produced it. So it is the same misattribution the
in-process guard exists to prevent, across a boundary neither table spans — but wider than that
guard's own case, and wider than anything `request_diff` could produce, since that only ever backed
up files this turn's own tools named. Accepted rather than solved — a _turn_ has no
cross-process identity to compare, so telling "another process is mid-turn in my window" from "a
process crashed here earlier" would mean writing that identity down somewhere, which is a design of
its own. Multiple instances are a normal setup here, so this is worth revisiting rather than
forgetting.

**The in-memory session table is swept the same way, and for the same reason.** `sweep_stale` runs
on every `ensure_baseline` for a new handle — that is, every time _another_ chat in this Neovim
starts a turn — so reaping purely by age would drop the session of a turn still running past the
TTL, which a long agent run reaches routinely. The next tool of that turn would then find no
session and re-baseline against the tree as it stands, so everything it changed before the sweep
falls out of the diff with no warning and no fallback: the silent loss again, through a third door.
It therefore asks `ActiveStreamRegistry` whether the request is still running — the same registry
that tells `ChatBuffer:is_responding()` a run is over — and keeps the TTL only as the outer bound
that stops the table growing when a stream never registered.

**Ref cleanup does cross that boundary, and has to**, because deleting a ref another process is
relying on is an action rather than a misreading. `sweep_refs` guards twice. It first asks the
instance registry whether another live Neovim sits on this root and skips the sweep entirely if so
— the same PID-filtered `registry.list()` that `hook_cleanup` uses to avoid deleting another
process's in-flight `.req`/`.res`. What the registry knows is each instance's own cwd, not which
worktree its chats run in, so it can under-match; the second guard is age, deleting only refs older
than the session TTL. Age alone was not enough — a turn running longer than the TTL, ordinary for a
long agent session, would age into the "leftover" bucket while still live — and the registry alone
is not either, hence both.

The registry entry's `worktree_root` is resolved by `send_message` and passed down as
`opts._worktree_root`; the adapters copy it into the entry the same way they copy `chat_bufnr`.
Resolving it inside `stream()` instead would put a synchronous `git rev-parse` on every stream
start, including the utility calls that produce no diff at all.

**Changes to `.gitignore`d files are invisible to the snapshot only while they are untracked**,
which is the trade that keeps `git add -A` cheap. The distinction is git's, not ours: `.gitignore`
governs what gets _added_, so a file that is already tracked keeps showing its modifications even
when it matches an ignore pattern — verified by committing a file with `add -f` and watching the
next snapshot diff report it. A genuinely untracked build artifact a Write tool reported anyway
still reaches `### Modified Files` through `extra_paths` — listed, with no patch section, matching
what `request_diff.generate` already did for files it could not back up.

## Concurrent Execution Support

vibing.nvim supports running multiple chat sessions simultaneously without interference:

**Multiple Chat Windows:**

- Each chat buffer maintains its own session ID
- Sessions are managed via unique handle IDs
- Old sessions are automatically cleaned up when starting new messages

**Session Management:**

- Handle IDs: `hrtime + random` ensures uniqueness across concurrent requests
- Session lifecycle: Created → Used → Automatically cleaned up when stale
- `cleanup_stale_sessions()` removes completed sessions while preserving active ones

See `handbook/adr/002-concurrent-execution-support.md` for architectural details.

**Directory creation is a shared-state operation here.** `vim.fn.mkdir(path, "p")` is not atomic —
it walks the path creating each component and raises `E739` when another process creates one
first. That is routine rather than theoretical: the instance registry is machine-wide, a project's
`.vibing/` is shared by every chat open on it, and the test suite runs one child Neovim per spec
file. Measured at 9 failures in 200 concurrent calls, and it is what made `tests/view_spec.lua`
flake in CI (#576).

Every directory creation therefore goes through `core/utils/fs.lua`'s `ensure_dir`, and
`fs_spec.lua` fails the build if a direct `vim.fn.mkdir` reappears anywhere in `lua/`.

`ensure_dir` **retries**; catching the error and re-checking is not enough, which is worth knowing
before simplifying it. The component that collided is often an intermediate one, and the process
that won it has not necessarily reached the leaf yet — so the loser's `fs_stat` on the leaf
legitimately finds nothing. Catch-and-recheck still failed 3 times in 200; retrying measured 0 in 320.

Only the race is swallowed. Every other way `mkdir` fails — a read-only filesystem, a permission
denial, a file where the directory should go — raises `E739` as well, and `ensure_dir` re-raises
those with the original message. Callers were written against `vim.fn.mkdir`'s raising contract,
so returning a quiet `false` instead would leave eighteen of them continuing as though the
directory existed.

## Chat Fork

`:VibingChatFork` creates a branched conversation from the current chat session.

**Session Lifecycle:**

```text
Source Chat (session-abc)
  │
  ├─ User sends messages... CLI resumes session-abc
  │
  └─ :VibingChatFork right
       │
       Fork Chat (session_id: session-abc, forked_from: source.md)
         │
         ├─ First message → CLI: claude -p --resume session-abc --fork-session
         │                  → CLI returns new session-def
         │                  → frontmatter updated: session_id: session-def
         │                  → forked_from cleared
         │
         └─ Subsequent messages → CLI resumes session-def independently
```

**Key Design Decisions:**

- Fork inherits the source's `session_id` directly in frontmatter (no separate side-channel)
- The `forked_from` frontmatter field indicates a pending fork; `opts._is_fork` makes the command
  builder emit `--fork-session` right after `--resume`
- After the first response, `forked_from` is cleared and `session_id` is updated to the new value
- This avoids `BufReadPost`/`attach_to_buffer` lifecycle issues where in-memory state would be lost
- `ForkedChatScanner` automatically updates `forked_from` links when source files are renamed

**Implementation:**

- `lua/vibing/application/chat/use_cases/fork.lua` - Fork use case
- `lua/vibing/infrastructure/link/forked_chat_scanner.lua` - Link synchronization scanner
- `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` - `--fork-session` flag

## Subagent Chat

`:VibingSubagentChat` opens a buffer bound to one subagent (`Task`/`Agent`) this chat started, so
the conversation with that agent can continue after the turn that spawned it ended.

**How the pieces connect:**

```text
Parent chat (session-abc)
  │
  ├─ Agent tool runs; its tool_result ends with
  │    agentId: ab2e... (use SendMessage with to: 'ab2e...' ...)
  │  → cli_event_processor writes `<!-- subagent: ab2e... type=general-purpose -->` into the
  │    chat text (subagent_marker.lua), so it is saved with the file
  │
  └─ :VibingSubagentChat
       │  subagent_finder scans the buffer for those markers (picker when there is more than one)
       │
       Subagent chat (session_id: session-abc, subagent_id: ab2e...)
         │
         └─ Every message → claude -p --resume session-abc  (NO --fork-session)
                          → --allowedTools gains Agent,Task,SendMessage,ToolSearch
                          → system prompt tells the model to relay via SendMessage(to: ab2e...)
```

**Why the session_id is shared permanently** (verified against the real CLI, not assumed): a
subagent's transcript lives under the _parent_ session's directory
(`.../<session_id>/tasks/<agentId>.output`). Resuming the parent session from a brand-new CLI
process and calling `SendMessage` works. Adding `--fork-session` does not — the forked session gets
a new id and `SendMessage` fails with `No transcript found for agent ID`. So unlike a fork, this
chat must never diverge, and `forked_from` is never written; `subagent_id` is the marker instead,
and `send_message.lua` sets `opts._subagent_id` rather than `opts._is_fork`.

**The cost of that:** two buffers now resume one `session_id` for good. Two
`claude --resume <same id>` processes would append to the same transcript concurrently, so
`send_message.lua` hard-refuses a send while another buffer's stream holds the same session
(`ActiveStreamRegistry.find_other_active_for_session`), before `start_response()` and without
touching the unsent `## User` line. Switching between the two buffers also re-diverges the shared
session's prompt cache, since each carries a different system prompt — accepted, not solved.

`SendMessage` resumes the agent in the background and returns immediately, so one request can now
produce two `result` events in a single CLI process lifetime. That is handled: `handle_result_event`
is idempotent and the exit handler fires once, on process exit, with both turns' output.

Built-in `Explore`/`Plan` agents are one-shot and return no `agentId`, so no marker is written and
they simply never appear in the picker.

Forking strips the markers from the copied body (`SubagentMarker.strip`): a fork diverges to its
own session on the first message, and those agents only exist under the original one, so keeping
them would offer a binding the CLI cannot resolve.

**Implementation:** `infrastructure/adapter/modules/subagent_marker.lua` (capture),
`presentation/chat/modules/subagent_finder.lua` (scan),
`application/chat/use_cases/subagent_chat.lua` (open, with a dedup check so one agent never gets two
rival buffers), `presentation/chat/controller.lua` → `handle_subagent_chat`.

## Multi-Agent Orchestration

One chat can create and drive other chats: `nvim_chat_create` (MCP) →
`infrastructure/rpc/handlers/chat.lua` → `application/chat/use_cases/create_chat.lua` →
`view.render`. The orchestrator briefs each worker with `nvim_chat_send_message` and polls it with
`nvim_get_buffer`. The workflow is the bundled
`claude-plugin/skills/vibing-orchestrate/SKILL.md`; there is no command and no scheduler — the
whole feature is three MCP calls and a skill.

Nothing new was needed to keep the workers apart. Each chat buffer already owns its own session
id and handle id (see "Concurrent Execution Support"), so parallel workers are the existing
concurrency guarantee being used rather than extended.

The use case is the fork/subagent shape: it returns a `ChatSession` and touches no presentation
code, and the RPC handler is what renders it. That is also why position validation sits in the
handler — it is an argument the RPC caller supplied, not a property of the session.

Four things it does differently from `:VibingChat`, each for a reason:

- **`position` defaults to `back`.** The chat exists as a listed buffer with no window. A worker
  the model created is not something the user asked to look at.
- **The chat file is written immediately** (`save_now` in the handler), matching `fork.lua`.
  `:VibingChat` leaves the file unwritten until `update_session_id` fires on the first response,
  so returning the path any earlier would name a file that does not exist.
- **`working_dir` is validated up front.** It is a git-root-relative path like the frontmatter
  field, resolved through `Git.resolve_working_dir`. A missing directory is rejected at creation;
  accepted, it would produce a chat that only fails on its first request, in a buffer the user
  is not watching.
- **The chat file still goes to the configured `save_dir`,** not inside `working_dir`. A worker
  attached to a worktree has to outlive `git worktree remove`, and this matches
  `vibing-worktree-create`, which only rewrites an existing chat's frontmatter. (The pre-existing
  and never-called `use_case.create_new_in_directory` does the opposite; `create_new` takes an
  optional `working_dir` instead.)

`view.render` now returns its `ChatBuffer` and replaces the `window` table before applying a
one-off `position`. It used to assign straight into `chat_buf.config.window.position`, and
`ChatBuffer` holds a reference to the live `config.chat` table — so a single `back` render changed
the user's default position for the rest of the session, right down to `Config.defaults`, which
survives a later `setup()`. Harmless enough at one `:VibingChat back` a day; not harmless when an
orchestrator opens three workers that way. Note that `vim.tbl_deep_extend("force", {}, cfg)` does
**not** fix it: with an empty base nothing collides, so every nested table is assigned by
reference and `config.window` stays the same table.

**Completion detection is a status field, not a text heuristic.** `nvim_get_buffer` passes
`include_chat_status` to `buf_get_lines`, which attaches `presentation/chat/modules/chat_status`'s
verdict: `"responding"` when `ChatBuffer:is_responding()`, one of `"waiting_approval"` /
`"asked_question"` / `"error"` when the last turn stopped for a reason worth naming, `"idle"`
otherwise, and nothing at all for a buffer that is not a chat. Reading the transcript's shape
instead would call a turn that died on an error, or one part-way through silent tool calls,
complete.

`is_responding()` needs two signals, and the second one is **not** `_current_handle_id`'s
existence. `_is_sending` covers `<CR>` until the adapter spawns the CLI; after that the handle id
is what marks the run — but `send_message.lua` deliberately never clears it on completion, so the
next `send_message()` can kill a process that outlived its own `result` event. Read as a boolean
that field therefore reports every chat as `responding` forever after its first turn, which is the
one answer an orchestrator's polling loop can never recover from. So the second signal is
`ActiveStreamRegistry.get(handle_id)`: all four adapters `register` when the stream starts and
`unregister` in `wrapped_on_done`, which makes the registry the only place that knows a run is
over without also being the place that has to remember how to kill it.

One window stays uncovered: `_handle_response` clears `_is_sending` before the `vim.schedule` that
appends the next `## User`, so a poll landing in that tick reads `idle` while the buffer is still
growing. The reply itself is already complete by then — what is pending is the diff footer. The old
boolean check did cover this window, but only as a side effect of being true forever.

The flag is opt-in rather than a new return shape because the MCP server installs at Claude
Code's _user_ scope and updates independently of the plugin: without a parameter to key on, a
newer Neovim answering an older server would hand it an object where it calls `.join()`. Both
directions of that skew are covered — the Lua side returns the bare array unless asked, and the
Node side accepts either shape.

`idle` means "no request in flight", not "succeeded". The three named stops carve out the cases
that used to hide inside it — a turn that ended on an error, one holding a tool-approval prompt,
one that asked a question — but what is left is still only "nothing is running": a worker that
finished half its brief and stopped is `idle` too. Whether the _task_ is done is something only the
worker's own report can say, which is why the notification below never claims it.

The reason lives on `ChatBuffer._stop_reason`, and **each of its three writers sets it at the moment
the fact becomes true** rather than a single pass reconstructing it at the end:
`insert_choices` writes `asked_question`, `insert_approval_request` writes `waiting_approval`, and
`mark_turn_error` — a callback `_handle_response` fires on its two failure paths — writes `error`.
Last write wins, which is right because each of those events is itself where the turn stops.

Deriving it at the end instead is the version that looks tidier and is worse: `add_user_section()`
clears `_pending_choices`, so the derivation would have to be ordered ahead of that call, and an
ordering rule that only a comment enforces is one a later edit silently breaks. `send_message()`
clears the field, which is the one piece of bookkeeping left: a turn that dies before its next send
must not leave its reason describing the following turn.

`mark_turn_error` skips two kinds of turn, and both exclusions are load-bearing rather than tidy:
what `chat_status` calls `error` is what branch 2's exception wakes the parent for, so anything
that is really still _waiting_ must stay out of it.

- **`_cancelled`** — a question and an approval prompt both stop the turn _by cancelling it_, and
  the reason was already written by `insert_choices` / `insert_approval_request`.
- **`_rate_limit_info`** — the limit branch above has already parked the turn as a scheduled send
  or an auto-resume, so it will restart on its own. `response.error` still holds the limit text
  (`RateLimit.merge` reads it as one of its inputs and does not clear it), so without this guard
  _every_ parked turn reports `error` and an orchestrator reads a healthy worker as failed.

A parked turn is therefore `idle`, which is the pre-#640 behaviour: distinguishing "waiting on a
reset" would be a fourth stop reason, and that was deliberately left out of this change.

A status the MCP server has no wording for is **named rather than dropped**. `CHAT_STATUS_TEXT` is
a lookup table, and rendering nothing for `error` or `waiting_approval` would read as a healthy
chat — the same silent-ignore failure `plugin_dirs`' manifest check exists to prevent — so a miss
falls back to a line carrying the raw status. That matters because the server is versioned
separately from the Lua side and can be handed a value added after it shipped.

**The relationship is recorded in frontmatter, not in the transcript.** `orchestrated` on the
orchestrator, `orchestrated_by` on the worker, both git-root-relative path lists written by
`application/chat/orchestration_link.lua` when `nvim_chat_create` or `nvim_chat_send_message` is
given an optional `from_bufnr`. `infrastructure/link/orchestration_chat_scanner.lua` keeps them in
step through `:VibingSetFileTitle`, alongside `ForkedChatScanner`.

Before this, the only record was prose the skill told the orchestrator to write into its own
reply, and it decayed two ways: **bufnrs are per-session** (a restart makes the number point at
some unrelated buffer) and **file paths get renamed out from under it** by `:VibingSetFileTitle`.
Frontmatter plus a rename scanner is how `forked_from` already solves exactly this, so the shape
is borrowed rather than invented.

Four details are load-bearing:

- **`from_bufnr` is optional, in both directions of version skew.** The wire format carries no
  protocol version, so an older Neovim ignores the extra key and an older MCP server never sends
  it. Requiring it would turn a forgotten argument into a refused send — a worse failure than a
  missing link, and one that would break every existing caller at once. Present-but-wrong is the
  opposite case and errors the call (`bufnr.resolve_from_bufnr`, #661): a number that names no
  chat buffer — typically one remembered from before a Neovim restart — used to drop the link
  _and_ the completion subscription in silence while the caller was told the call succeeded, and
  the MCP caller is the one party that can correct it. The check runs before any side effect, so
  a refused `nvim_chat_create` leaves no orphaned worker chat behind.
- **The link is written before the message is sent.** `update_frontmatter_list` edits the buffer
  directly, so writing after the worker's reply starts would race its streaming.
- **`update_frontmatter_list` writes to the buffer, not to disk**, and the rename scanner reads
  disk. So `orchestration_link` saves both files itself. The sender is the one that needs it:
  `:VibingChat` holds the first write until the first response, so an orchestrator that dispatches
  on its opening turn has no file for a scanner to find.
- **One scanner reads both keys.** Splitting it per direction would double the full-file reads and
  the `git rev-parse` calls over the same directory, and a rename has to update whichever side
  names the old path anyway.

Copying `ForkedChatScanner` wholesale is the trap here. `forked_from` is a scalar, so its
`update_link` hands the whole key to `Frontmatter.update`; doing that to a list drops every other
element. `OrchestrationChatScanner` replaces the matching element and dedupes afterwards, since a
rename can collide with an entry the list already had. Two parser behaviours bite the same way: an
empty list parses to a **truthy** `{}`, and a hand-written `orchestrated: path.md` parses to a
**string** rather than a list.

**A send whose reverse is already recorded writes no link**, and that is what keeps the record a
tree rather than a set of pairs. A push report (#643) is a `nvim_chat_send_message` in the opposite
direction from the dispatch, so writing it as a new relationship put each worker into its
orchestrator's `orchestrated_by` — and `cli_command_builder` builds the worker prompt out of that
key, so the orchestrator was then told to report to its own worker. Reproduced across three chats
before fixing. The mechanism still cannot tell a report from a request at send time, which is the
constraint `completion_notifier` documents; what it can read is whether the recipient is already
this chat's orchestrator, and that answers the direction question on its own. One side recording it
is enough, since `link` tolerates a half-written pair. The cost is that a genuine A⇄B mutual
orchestration cannot be recorded — a cycle, and not a shape worth supporting.

A one-sided write warns rather than failing the send: the link is a record, and rename sync still
works from whichever side did get written. Fork and subagent chats do **not** inherit these fields
— `inherited_frontmatter.from_source` is an explicit whitelist, and a fork claiming its parent's
relationships would be claiming work it was never given.

**Completion is pushed, not polled** — `agent.chat_notifications.enabled`, default `false` because
it spends tokens unattended. The whole mechanism is that **the send is the subscription**: when
`nvim_chat_create` / `nvim_chat_send_message` receive `from_bufnr`, `completion_notifier.subscribe`
records an A←B edge, and when B's turn ends A is given a new turn saying "B stopped, go read it".
A worker asking its orchestrator a question is the same path in reverse — it just calls
`nvim_chat_send_message` itself.

There is no waiting anywhere, and there cannot be: the CLI process dies when its turn ends, so the
only way to deliver anything to a chat is to _start a new turn on it_.

The completion event fires from the `callbacks.add_user_section` wrapper in `buffer.lua`, and
every word of that placement is load-bearing:

- **The four completion paths in `_handle_response`** (session corruption, mote `finalize`,
  no-file-change, git patch `finalize` — two of them inside `vim.schedule`) all converge on that
  one callback. Nothing else does.
- **Not `ChatBuffer:add_user_section()` itself**, which the slash-command path also calls — that
  would report a completion for a turn the model never ran.
- **Not next to `clear_sending()`**, which under `diff.tool = "mote"` runs before `finalize()`
  writes `### Modified Files`. A reader woken there would see an unfinished transcript, the same
  window `chat_status` documents.
- **After the handle_id mismatch guard**, so a cancelled turn completing late fires nothing.

It goes out as a `User VibingResponseDone` autocmd rather than a direct call so a user's own config
can hook it too — before this there was no `nvim_exec_autocmds` anywhere in `lua/`.

**Delivery refuses a busy buffer, and that is the sharpest edge in the feature.**
`ChatBuffer:send_message()` cancels the in-flight request before starting a new one, so delivering
into a responding chat would kill the turn it is in the middle of; and its `_is_sending` guard
returns _silently_, so `ProgrammaticSender` used to report success for a message it never sent —
leaving an orphan `## User` section that became the body of the user's next `<CR>`. A dispatched
chat normally keeps working after dispatching, so the shorter the worker's task the more likely
this window is. So `ProgrammaticSender` now refuses before appending (rather than appending and
rolling back), and `application/chat/message_queue.lua` queues instead, flushing on the
recipient's own completion event. Queued items coalesce into one message: three workers finishing
while the orchestrator is busy is one turn, not three.

**That queue carries bodies as well as notices**, which is what `nvim_chat_send_message`'s
`queue_if_busy` is (#642). Both kinds need the same wait — the only way to deliver anything is to
start a turn, and a turn can only be started on a chat that is not responding — so they share one
queue and one flush, and a turn woken by it can carry both. An item with a `body` is a relayed
message and one without is a completion notice — there is no separate kind flag, because a
derivable one goes stale. `application/chat/delivery_message.lua` renders the coalesced turn and
keeps the notice-only case byte-identical to what it was, since that is still the common shape;
splitting it out keeps prompt wording out of the queue's state machine.

Four things about it are not incidental:

- **`queue_if_busy` is not gated on `chat_notifications.enabled`, and the drain is not either.**
  That flag decides whether vibing.nvim volunteers a watchdog wake-up; a queued message is a
  delivery the caller explicitly asked for. Gating it would mean a worker's report vanishing in
  silence on the default config. So `on_response_done` drains first and unconditionally, and only
  the `edges` half below it reads the flag.
- **It is off by default on the tool, in both directions of version skew.** An older Neovim
  ignores the key and refuses a busy chat exactly as before, which is what a caller that did not
  ask to queue already expects; an older MCP server never sends it. It also only covers
  `"responding"` — an invalid buffer or an empty message is not something waiting fixes, so those
  still error. That is why `ProgrammaticSender` grew a `is_responding` predicate rather than the
  caller matching on the error _text_ `validate` raises, which would stop working the day the
  wording changed, silently.
- **The orchestration link is written just before delivery, not when the message is queued.**
  `update_frontmatter_list` edits the recipient's buffer, and the precondition for queueing is
  that the recipient is streaming — so the usual "link before the send" ordering has to be kept by
  moving both, not by writing early. Flush only ever delivers into an idle chat, which makes that
  the one safe moment. A message whose recipient is deleted before delivery therefore leaves no
  record of an exchange that never happened.
- **The queue is capped per buffer (20) and a message past the cap is refused, not dropped.** A
  notice can be deduplicated by the bufnr it is about; a body cannot, so a worker in a retry loop
  would otherwise pile up without bound. The refusal is returned to the sender as an error, which
  is the whole point — a report that disappears quietly is the failure this mechanism exists to
  remove. The one case that cannot be reported back is a _notification_ arriving at a full queue,
  since its edge is already consumed by then; that one warns. `forget` follows the same rule when
  a chat is deleted: a notice _about_ that chat has lost its subject and goes, but a queued body
  whose **sender** was the deleted chat is still deliverable, so it loses only the sender's name
  and arrives anonymously.

**A message the sender delivered itself silences the watchdog for one stop.** A send is one event
with two opposite consequences, so `completion_notifier.on_sent(from, to)` performs both rather
than leaving the pairing to each caller: it records `edges[to][from]` (the send _is_ the
subscription), and marks `edges[from][to]` as already-reported, dropping any notice about `from`
already sitting in `to`'s queue. "B stopped, go and read it" is the same errand as B's own report,
and A does not need waking twice for it. The reversed indices are the reason it is one function:
written out at a call site, `subscribe(a, b)` next to a suppression of `edges[a][b]` reads like a
typo.

**It is a mark and not a deletion, and that distinction is the whole of #638 again.** Nothing at
send time can tell a final report from a progress note — and in a tree the middle node's first
message is _always_ a progress note, because it stops once to wait for its own worker and only
writes the real answer after that worker reports. Deleting the edge there would lose the
orchestrator's subscription permanently, defeating the hold this PR's base branch added. So the
mark suppresses exactly one stop: `on_response_done` clears it when the drain restarts the chat
(the report was not final after all), and otherwise consumes the subscription silently, since the
one-shot edge was spent on a delivery the subscriber already received. That consumption happens
**before** the `enabled` gate, not after — a mark is a one-stop temporary, so a completion the
gate declines to act on still has to spend it, or a spell of the feature being off leaves a stale
mark that silences the first genuine edge after it is turned back on.

**Queued messages do not spend hop budget.** A direct send to an idle chat has never counted
against `max_hops` — it just starts a turn — and `queue_if_busy` is that same send arriving late.
Only notices carry a `depth`, and the queue treats it as an opaque number it hands back on delivery
so the notifier can raise its counter; the queue itself never interprets it. Bounding A⇄B
ping-pong through direct sends is #644's pair-wise counter, not this.

**A chat drains its own queue before it notifies anyone, and a turn that drained is not reported as
a completion at all.** `on_response_done` tries `flush(bufnr)` first and returns leaving
`edges[bufnr]` intact when it delivered, because a delivery _is_ a restart — so the turn that just
ended was an intermediate one, and the real answer is still being written.

The order used to be the reverse, on the reasoning that draining first would let a subscriber be
told "B stopped" about a B that had already started again. It does not prevent that. The order
fixes only who is _sent to_ first within one tick, and a subscriber is a separate CLI process that
reads seconds later — by which time the synchronous drain has long since restarted B. The edge is
one-shot, so B's actual report, the turn after the restart, then had nothing left to notify
through. In a tree of chats where a middle node waits on a leaf this happens every time rather than
sometimes: "B's queue is non-empty" _means_ "B is about to restart" (#638).

A drain the recipient **refuses** — it is responding, or the user has a draft in it — restarts
nothing, so subscribers are notified exactly as before.

**The mirror ordering is covered by a second branch, which is #640.** When the leaf finishes
_after_ the middle chat's dispatch turn rather than before — the commoner case, since dispatching
takes seconds and the leaf takes minutes — that turn's queue is empty, so the drain above catches
nothing. The signal that does catch it was already in the table: `edges[c][b]` exists from B's send
until C completes and means "B is waiting on a chat that has not finished". So `on_response_done`
now reads as three branches, tried in order:

1. **The queue drained** — B restarts in this tick, so nothing is delivered and `edges[b]` is kept.
2. **B is waiting on chats it messaged** — the turn that just ended was B parking on a barrier, so
   the parent's notification is held and `edges[b]` is kept.
3. **Neither** — B has really stopped, so subscribers are notified and the edges consumed. This is
   the watchdog.

Branch 2 has one exception, and it is what stops the barrier becoming a trap: a chat that stopped
to **ask a question, wait on a tool approval, or fail** fires to its parent anyway. Nobody is
looking at a worker's buffer, so holding those would leave the whole tree waiting on an answer no
one can give.

The predicate reads `ChatBuffer:get_stop_reason()` directly and asks only whether it is non-nil —
**not** `chat_status`. Going through that vocabulary would mean encoding "must not match
`responding` or `idle`" here, so a stop reason added later would be classified as "needs no
attention" by omission, in silence. Testing the primitive puts a new reason on the firing side by
default, which is the safe direction. `chat_status` stays what it is: the presentation join of
`is_responding()` and the reason, for the MCP field.

**Branch 2 excludes edges pointing back at its own subscribers, and that exclusion is what keeps
it from deadlocking.** `on_sent` makes every send a subscription in both senses — B reporting to A
subscribes B to A's completion — so counting edges naively, a worker that reports to its
orchestrator is "waiting on" that orchestrator. Holding B's completion for A while A waits for B's
completion is a standoff neither side leaves. Nothing in the table says which send was a report
and which was a request, but the direction that _is_ readable is "this chat is waiting on my
completion", and someone waiting on you is not someone to hold your stop from.

What remains, after that exclusion, is the shape branch 2 is actually for: B is waiting on a chat
that is not waiting on B — a leaf it dispatched to.

Two limits are worth writing down, because the rules read more general than they are.

- **The hold is gated on a turn actually starting, not on the send being accepted.**
  `send_message()` returns "treated as a request", which is also true for a message _parked_ behind
  a usage limit (`_try_schedule_instead_of_send`) and for one `SendMessage.execute` drops at its
  no-adapter or shared-session guards — both `clear_sending()` and return without a stream, so no
  `VibingResponseDone` is ever coming. `flush` therefore reports the recipient's `is_responding()`
  rather than the send's own result: a turn that never began cannot be the one a subscriber waits
  for, and notifying now is exactly what the old order did.
- **A held edge still has no exit but `BufDelete`, and branch 2 widens the window.** Every edge
  used to be consumed on the subscribed chat's next completion; one that waits on a follow-up turn
  is stranded silently if that turn dies before reaching the `add_user_section` wrapper. Branch 2
  extends that from "until B's next turn" to "until every chat B messaged has completed", so a
  leaf whose Neovim-side turn vanishes without firing `VibingResponseDone` leaves its parent
  waiting for good. A leaf that merely _fails_ is fine — the failure path still reaches the
  wrapper, which is exactly what the `error` exception is there to convert into a notification.
  What is left uncovered is the process dying under it, and the recovery for that is the same one
  #639 names for a Neovim restart: a human sends a message in the stalled chat, which re-creates
  the edges. Accepted for the reason the module holds no timers.
- **A chat created and never briefed is an edge that never resolves.** `nvim_chat_create`
  subscribes at creation rather than at the first send, deliberately — so a forgotten `from_bufnr`
  on the brief cannot silently cost the notification. Branch 2 now reads that same edge as "the
  creator is waiting on this chat", and a worker that is created and then never messaged runs no
  turn, so nothing ever consumes it. Its creator holds its own parent's notification indefinitely.
  Harmless at the top of a tree (the user is the parent), and the normal flow — create, brief,
  worker completes — clears it. Narrow enough to accept rather than key the barrier off a second
  "has been messaged" table.

None of that promises B's next turn is a report for A rather than a reply to the leaf either. Under
a one-shot edge, "when B next stops" is simply the best moment available.

Edges are **one-shot** — delivering consumes them, so a worker completing again without a fresh
send is silent, and A messaging B three times still notifies once.

**The chain is bounded per chat pair, not per chat.** A→B→A→B is a legitimate question-and-answer,
so this counts rather than detecting cycles: `max_round_trips` (default 8) is how many
notifications may be delivered between one pair of chats without a human `<CR>`, and `subscribe`
refuses once the pair is spent — with a warning, rather than declining in silence.

The pair is **undirected**. What is bounded is the A⇄B ping-pong, and a worker asking its
orchestrator a question arrives as `subscribe(B, A)` while the orchestrator's brief was
`subscribe(A, B)`. Two directional counters would give one conversation two budgets and put the
real ceiling at twice the configured one. The cost of that choice is that the unit is a
_delivery_, not a full exchange: an orchestrator waking on its worker's completion spends one,
but a worker's question and the orchestrator's answer spend two.

It used to be one counter per chat — `depth[bufnr]`, how many times that chat had been woken —
and in a tree that stopped the wrong thing (#644). An orchestrator is woken once per worker
completion, so five workers reporting in spent five of its eight hops before any ping-pong
happened at all: the limit fired on fan-in, which is the normal shape of the feature, and left
A⇄B free until that same shared budget happened to run out. Keyed by pair, fan-in costs each pair
one and only the ping-pong accumulates.

Moving to pairs also removed machinery, and the removal reaches across the module boundary. The
old counter had to be monotonic across a chain, so each edge carried the depth it was created at,
every queued item carried it onward as `Item.depth`, `MessageQueue.flush` returned the deepest of
them, and delivery raised the recipient to `max(current, deepest + 1)` — all of that to stop an
edge subscribed early and delivered late from lowering the count. A pair counter is incremented
from the delivery's own `(from, done)`, which _is_ the pair, so the queue stops carrying a number
it never interpreted. `flush` now reports **which** chats the delivered notifications were about
instead, and that list doubles as the "did anything go out" signal the wake budget needs — an
empty table for a turn that carried only queued bodies, `nil` for no delivery at all.

`max_wakes` (default 50) is the second bound: notifications delivered without a human `<CR>`,
counted across the whole editor. It exists for the shapes a pair counter is bad at, which are the
ones that spread deliveries over many pairs — an unbounded fan that never reaches the same chat
twice, and a long cycle (A→B→C→A advances three counters by one per lap). Which of the two limits
fires first depends on the shape and the configured values; at the defaults a 3-chat cycle is
still caught by `max_round_trips` first, at 24 deliveries, well under the budget.

It is deliberately **not** scoped to a connected component, and the reason is sharper than "more
work". The budget is checked in `subscribe`, and the escape it exists to catch — a fan reaching
chats never contacted before — has no `round_trips` entry at that moment, so component membership
is precisely unknowable for the case it guards. `edges` cannot supply it either: edges are
one-shot and consumed on delivery, so the live set is a transient slice rather than the chat
graph. The accepted cost is that two unrelated orchestrations share one budget — either can
exhaust it for the other, and a `<CR>` in either refills both.

Both reset on a manual `<CR>`, through `on_manual_send(bufnr)`. It is named for the event rather
than for the buffer, matching `on_response_done`, because it is not "clear this chat's state": it
is "a human acted", and what that implies is the module's to decide. So it drops every pair that
chat belongs to _and_ zeroes the tree-wide budget — a human typing anywhere breaks the "running
unattended" premise that budget guards, and keeping it would leave a chain the user is actively
steering unable to notify anyone until Neovim restarts.

The reset lives in the `<CR>` keymap callback rather than in `send_message()`, because delivery
itself goes through `send_message()` — resetting there would zero the counters on every hop and
disable the limits entirely.

**Both limits are checked only when the subscription is created, never again at delivery.** An
edge that was authorized while budget remained is still delivered after other edges have spent it,
so either limit can be exceeded by however many edges were live at that moment. Checking again in
`flush` was rejected: it would drop an already-authorized completion notice, and an orchestrator
silently never hearing that its worker finished is the exact failure this whole mechanism exists to
remove — worse than a one-off bounded overshoot, after which every further `subscribe` is refused
and the chain stops anyway.

A deleted buffer's pair counters go with it (`forget`), since Neovim reuses buffer numbers and a
stale entry would throttle an unrelated new chat on its first send. Emptied inner tables are
dropped along with the entry, in `round_trips`, `edges` and `reported` alike: `forget` runs from a
pattern-less `BufDelete` and short-circuits on `next()` over those three, so a table left holding
zero entries would disarm that fast path for the rest of the session and put a full scan back on
every ordinary buffer close.

The removed `max_hops` is not silently ignored: `config.lua` drops it and warns through
`notify.warn_once`, so the message appears once per Neovim session rather than once per `setup()`
— a config that calls `setup()` again does not repeat it. That is the same treatment
`diff.tool = "mote"` gets, and the three of them share the mechanism rather than each keeping a
flag. A limit that reads as configured while doing nothing is worse than one that was never set.

**The notification says "stopped", never "succeeded".** `idle` is also what a failed turn, a
pending tool approval, and an `nvim_ask_user_question` look like, so judging outcomes from the
event would repeat `chat_status`'s mistake. The message names each finished chat by path (with its
current bufnr in parentheses) and instructs A to read the transcript's tail — not the worker's
text, which would pull B's context into A for no reason.

**Reporting is the worker's job; the notification is a watchdog** (#643). A worker is told — by the
system-prompt line below, and again by the brief `vibing-orchestrate` has the orchestrator write —
to finish by calling `nvim_chat_send_message` on its orchestrator's path with `queue_if_busy: true`
and a summary that stands on its own. That is the path a healthy fan-out takes, and it needs
nothing from `chat_notifications`: `queue_if_busy` and the drain are ungated, so a report is
delivered whether or not the watchdog is switched on.

Which is what lets the notice be worded as a warning rather than a status line. `on_sent`'s
suppression mark drops the watchdog for the stop that follows a worker's own report, so a chat that
reaches `enqueue_notification` is one that stopped **without** reporting — likelier a failure, a
question or an approval prompt than a finished task. `delivery_message.lua` says so in as many
words, and the skill's step 5 splits the two wake-ups on that line: a report is read as text, a
watchdog notice sends the orchestrator to the transcript.

**Fan-in is a convention, not a barrier.** A chat that is both a worker and an orchestrator holds
its own report until every worker of its own has reported — stated in `vibing-orchestrate` step 7,
enforced by nothing. A barrier in the mechanism would have to answer "what if a child never
reports", and both honest answers are bad: a timeout, or a tree that stalls for good. The
convention instead tells the middle node to report early, naming the stuck child, when a child
stops on `asked_question` / `waiting_approval` / `error` — the same three exceptions branch 2
already makes. Worth revisiting if a middle node forgetting turns out to cost anything in practice.

A worker learns its orchestrator from a system-prompt line built out of its `orchestrated_by`
frontmatter. Only that direction is exposed: a worker's list is written once at creation and stays
byte-stable across turns (#469), while an orchestrator's `orchestrated` grows with each dispatch
and would move the cached prefix mid-conversation.

**Out of scope, deliberately:** the orchestrator still does not poll inside its own turn, and
nothing is persisted — the subscription table and the delivery queue are in memory only, since
Neovim dying takes the worker chats with it. Backends other than claude can be _notified_ (the
event is backend-agnostic) but cannot _subscribe_: `nvim_chat_send_message` is an MCP tool, and
codex/grok reach no MCP server, the same constraint `features.md` records for AskUserQuestion.

### Delivered sections

A message that arrived from another chat is written as its own section kind — `## Request`,
`## Report` or `## Notice` — instead of the `## User` a human types into. The grammar and the
three kinds are in `features.md` → "Message Timestamps"; what belongs here is why the seams are
where they are.

**`extract_role` answers `user` for all three, and that is the whole safety argument.** A
section's body _is_ the prompt handed to the CLI (`conversation_extractor.extract_user_message`
takes everything under the last `user` header), so a genuinely separate role would have to be
taught to the send path, the conversation extractor, `commit_user_message`, both daily-summary
parsers and the jump commands — and forgetting any one of them fails toward a delivered turn that
is never sent, which is the silent-loss shape this whole area exists to remove. Only the display
needed splitting, so only the display splits: callers that care read `parse_header().kind`.

**The header grammar has one home.** `timestamp.lua` writes and reads it; `grep_parser` used to
carry its own `^## User` patterns and now calls `extract_role`, because a second reader is a
reader that goes stale — delivered turns would have dropped out of the daily summary without
anything saying so. Its `grep -E` prefilter still names the kinds, which is the one place the list
is repeated, and deliberately: it only decides which lines are handed to the shared parser.

**Both delivery paths build the same text.** `handlers/message.lua` (immediate) and
`message_queue.flush` (queued) both go through `delivery_message.deliver`, which owns the
`section_for` → `build` → send ordering. Leaving those three at each call site is what let them
diverge — the queue wrapped each body in a `### From` heading and the direct send passed the raw
text through — so the same worker's report looked different depending on whether its orchestrator
happened to be mid-turn when it arrived. `section_for` names the sender in the section header only
when the delivery is exactly one body from one chat; `build` then drops the `### From` that would
otherwise repeat it two lines later. A coalesced delivery keeps the per-item headings and leaves
the section header unnamed.

**A delivery fills the empty unsent section rather than appending below it.** Every turn ends with
`add_user_section()` writing `## User <!-- unsent -->`; a human types into it, but
`ProgrammaticSender` appended a second section, so each delivered turn left a stranded empty
`## User` above it — one per turn, visible in any orchestrated transcript. It now drops a trailing
unsent section that is empty. Only empty: the approval prompt and the question list are rendered
into that same section, and dropping those would delete what the user was about to answer.

**The unsent-then-commit dance is kept for delivered sections too.** Writing the timestamp
directly at delivery would be simpler, but a send that lands under a usage limit is parked as an
unsent section and fired later (`auto_resume`), so the unsent form has to exist for these as well.
`commit_user_message` therefore stamps whatever kind it finds and preserves the `from`, instead of
replacing the header with a `## User`.

### Addressing a chat

**The chat file path is the identifier; the bufnr is a per-session resolution of it** (#641).
`nvim_chat_send_message` and `nvim_get_buffer` both take `file_path` or `bufnr`, and the system
prompt's orchestrator line leads with the path — `.vibing/chat/x.md (currently buffer 12)`.

The problem it fixes is that the durable layer was already right and only the volatile one was
being spoken. `orchestrated` / `orchestrated_by` hold paths, `OrchestrationChatScanner` keeps them
correct across renames, and none of that reached the model: a bufnr means nothing in a Neovim other
than the one that issued it, so a chat network resumed the next morning pointed every edge at some
unrelated buffer. Recovery is by design "a human kicks a node" (see #639), and a kicked node can
only re-attach if what its frontmatter records is also what it can address.

Five details are load-bearing:

- **A path that names no open chat is opened, not refused.** `application/chat/chat_locator.lua`
  does `bufadd` + `bufload` + `view.attach_to_buffer` — the same three steps `auto_resume` already
  used for exactly this case — and sets `buflisted`, matching what a `back` chat gets. Refusing
  instead would leave the restart case unreachable, which is the whole point.
- **It opens chat files and nothing else.** The check runs on the file's own content _before_ a
  buffer is created, so a rejected call leaves nothing behind. This is not fussiness about scope:
  a `file_path` that reaches `send_message` gets a `## User` section written into it, so accepting
  an ordinary source file would make sending a destructive edit of the user's work.
  `nvim_load_buffer` remains the way to read anything else.
- **Passing both `bufnr` and `file_path` is an error, on both sides of the wire.** Two names for
  one target is a sign the caller is confused about which chat it means, and quietly preferring
  one delivers into a chat nobody intended with nothing saying so. The advertised JSON Schema
  requires neither, since a `required` list naming two mutually exclusive keys reads as "pass
  both". `handlers/bufnr.lua`'s `resolve_chat_target` enforces it on the Lua side and
  `validation/schema.ts`'s `validateChatTarget` on the Node side — one function per side rather
  than one per tool, since the two tools disagree only about whether _neither_ is allowed
  (`nvim_get_buffer` falls back to the current buffer; a send has nothing to fall back to).
- **`from_bufnr` stays a bufnr**, and the asymmetry is deliberate: it names the _calling_ chat,
  whose number the system prompt restates every turn, so it is never stale.
- **The bufnr half of the prompt line is the cache-unstable half.** Closing or reopening the
  orchestrator changes it; so does `:VibingSetFileTitle`, which moves the path too. Each costs one
  #469 cache miss, accepted for a line that now survives a restart at all.

`ChatLocator.resolve_all` keeps an entry for a path it could not resolve, with no `bufnr`. Its
predecessor (`orchestration_link.resolve_bufnrs`) dropped those, which meant a worker whose
orchestrator was merely closed lost the prompt line entirely — the one case the path form exists
to serve.

**`bufnr` is a `0` that stays `0` on the send path.** `handlers/bufnr.lua` has two resolvers and
they differ in exactly this: `resolve` maps `0` to the current buffer, which is what the
annotation and highlight tools want, while `resolve_chat_target` hands it through. A send appends
a `## User` and starts a turn, so reading `0` as "whichever chat the user is sitting in" is the
same misdelivery the both-arguments refusal exists to prevent — and `nvim_get_buffer` advertises
`0` as the current buffer, so a model will try it here too. Passed through, `nvim_buf_get_lines`
still reads it as the current buffer while `view.get_chat_buffer(0)` refuses the send. Both
resolvers also treat an explicit JSON `null` as absent: `vim.json.decode` turns it into the truthy
`vim.NIL`, so a model spelling the unused argument as `null` would otherwise be told it named the
target twice.

**Under Lua/Node skew the read path now fails loudly**, which is the one place this differs from
`include_chat_status`. A Neovim too old to know `file_path` ignores it and answers for `bufnr or
0` — the current buffer — and that reads as a perfectly healthy transcript of the chat that was
asked for, reported `idle`. So `buf_get_lines` reports the buffer it actually read, and the MCP
handler refuses an answer that omits it whenever a `file_path` was passed. The send path needs no
equivalent: it errors outright when it can find no target.

## Key Patterns

**Adapter Pattern:** All AI backends (`claude_cli`, `codex_cli`) implement the `Adapter` interface
with `execute()`, `stream()`, `cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration,
automatically updating chat frontmatter without manual YAML editing.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a
vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language for chat,
supporting multi-language development workflows.

## Git Worktree Integration

Worktree-backed development goes through natural-language requests backed by the
`vibing-worktree-{list,create,attach,run,finish}` Claude Code skills bundled with this plugin
(`claude-plugin/skills/vibing-worktree-*`), not through a vibing.nvim chat command. There is no
bespoke lifecycle script or metadata file — worktrees are created with plain
`git worktree add -b <branch> .vibing/worktrees/<branch>/` and removed with
`git worktree remove`; a worktree's existence on disk is its entire state. The chat's own
`working_dir` frontmatter field (unchanged by this) is what keeps a conversation attached to its
worktree across turns. See `claude-plugin/skills/vibing-worktree-list/SKILL.md` (and its sibling
`-create`, `-attach`, `-run`, `-finish` skills) for the full list/create/attach/finish workflow.
