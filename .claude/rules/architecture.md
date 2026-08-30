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
was drift rather than intent. `cancel()` now kills the CLI's children before the parent on every
backend; claude killed only the parent, so the shells its tools spawned kept the stdout pipe open
and `vim.system()`'s exit handler — which waits for that pipe to close — never fired, leaving the
chat UI frozen. And `execute()` now cancels a run that outlives its timeout instead of returning
and leaving the process alive; only grok did that. `cli_runtime_spec.lua` runs both over every
backend.

The pkill is asynchronous (`vim.system`, grok's form) rather than blocking (`vim.fn.system`, what
codex and copilot used), because `cancel()` can be reached from a `vim.schedule` callback and
should not stall the main loop there. The cost is that the parent's `kill(9)` is not sequenced
after the children's: signal delivery is effectively immediate, so an orphan is theoretical rather
than observed, but it is a real ordering change and not something a test can pin while the call is
fire-and-forget. Revisit by chaining the parent kill onto the pkill's `on_exit` if orphans ever
show up.

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
- bin/list-commands.ts         - Slash command/skill enumeration for completion
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

**Completion needs the same list, and gets it by argv rather than by rediscovery.**
`bin/list-commands.ts` only knew `~/.claude/plugins/installed_plugins.json`, where a
`--plugin-dir` plugin cannot appear. Teaching it the `.vibing/plugins` convention would mean
writing the same working-directory handling in Lua and TypeScript, so `skills.lua` appends the
already-resolved paths to the `jobstart` argv and `resolveSessionPluginDirs` scans them. The
agent provider (`completion/providers/agents.lua`) merges the same entries ahead of the installed
ones — without it `nvim-navigator` would load in the CLI and never appear in completion.

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
  takes a baseline in it, deleting only refs older than the session TTL — the ordering rules out a
  live ref of this process (the sweep runs on a root's _first_ baseline, when no session on that
  root exists yet), and the age bound rules out a live one belonging to another Neovim, which no
  in-memory table can see.
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

**`request_diff.lua` stays** as the fallback for the two cases a snapshot cannot serve, decided in
`_handle_response`:

| Condition                                       | Path           |
| ----------------------------------------------- | -------------- |
| `working_dir` is not inside a git repository    | `request_diff` |
| Another turn's write window overlapped this one | `request_diff` |
| Otherwise                                       | `git_snapshot` |

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
other's Bash-driven changes as its own. That is the same misattribution the in-process guard exists
to prevent, across a boundary neither table spans. Accepted rather than solved — a _turn_ has no
cross-process identity to compare, so telling "another process is mid-turn in my window" from "a
process crashed here earlier" would mean writing that identity down somewhere, which is a design of
its own. Multiple instances are a normal setup here, so this is worth revisiting rather than
forgetting.

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
verdict: `"responding"` when `ChatBuffer:is_responding()`, `"idle"` otherwise, and nothing at all
for a buffer that is not a chat. Reading the transcript's shape instead would call a turn that died
on an error, or one part-way through silent tool calls, complete.

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

`idle` means "no request in flight", not "succeeded": a worker that failed, that is waiting on a
tool-approval prompt, or that asked a question is idle too. The skill says so, because the
distinction is not something the status can carry.

**Out of scope, deliberately:** workers cannot message the orchestrator back, there is no
event-driven completion notification, and the orchestrator does not poll inside its own turn — it
hands control back to the user and reports when asked. All three would need a channel that does
not exist yet; the MVP is "distribute, observe, report".

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
