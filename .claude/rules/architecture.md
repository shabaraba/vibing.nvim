# Architecture

Invariants and a map. Every "why" is one link away; read the linked file before changing that path.

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

`cli_command_builder.lua` assembles the argv; `cli_event_processor.lua` turns stream-json lines
into chunk/tool events. Everything that needs to call _back into_ Neovim mid-turn (permission
decisions, approval UI, `AskUserQuestion`, rate-limit reporting) goes through the RPC server rather
than the stream, registered by `.vibing/hook-settings.json`
(`hooks/settings_generator.lua`).

The hook contract is `handbook/architecture/cli-integration.md`. Three invariants from it apply
whenever this path is touched:

- **The hook fails closed.** If `nc` cannot connect or no response arrives, it exits 2 and the
  tool is denied. Do not add a path that exits 0 on an internal failure.
- **The `.res` file carries three decisions, not two** — `deny`, `allow` and `defer`. Exiting 0
  in silence is `defer` ("no opinion"), _not_ an approval.
- **Only vibing-nvim's own MCP tools get `allow`; everything else permitted gets `defer`.**
  An `allow` skips the CLI's own gate, and with it the user's `settings.json` deny rules, which
  `--setting-sources user,project,local` still pulls in.

The comm directory path has exactly one definition, `infrastructure/rpc/comm_dir.lua`, shared by
the handlers, the cleanup routine and `bin/hooks/*.sh`.

## Backends and Their Seams

`claude_cli.lua` (default), `codex_cli.lua`, `copilot_cli.lua` and `grok_cli.lua` implement the
adapter interface. Implementing it is not the same as feature parity — `AskUserQuestion` is
Claude-only (`handbook/features/chat-ui.md`).

- **`core/constants/agents.lua` is the single definition of what a backend is** — module path,
  export name, description, model candidates. `factory.lua`, `modes.lua`,
  `completion/providers/frontmatter.lua` and `infrastructure/init.lua` all derive from it, so
  adding a backend is a one-file change. It deliberately requires nothing, which keeps the
  dependency one-way.
- **A backend name belongs in that backend's own module; shared code takes what it is handed.**
  `rpc/handlers/permission.lua` contains no backend name.
- **`bin/hooks/pre-tool-use.sh` is the one deliberate exception**: the deny _signalling_
  convention differs (claude: exit 2 + stderr; copilot: exit 0 + stdout), and that is shell
  semantics.
- **Each `<backend>_tool_vocabulary.lua`'s three normalizations are order-dependent.**
  `normalize_payload` (key names) must run before `to_canonical` (tool name) and `normalize_input`
  (where the path lives), or every rule misses and the turn stalls until the hook fails closed.
- **Grok discovers project hooks only inside a git repository** (outside one the gate would
  silently allow everything, so `ensure()` warns), and **copilot's hook is injected as a throwaway
  plugin** under `.vibing/copilot-plugin/` via `--plugin-dir`, with a schema that is not claude's.

Why each seam exists and which CLI version each shape was captured from:
`handbook/architecture/cli-integration.md` → "Backend Seams".

## Plugin Loading and Command Discovery

vibing.nvim's own Claude Code plugin is **not installed**: `cli_command_builder` passes
`--plugin-dir <path>` once per directory resolved by `infrastructure/plugins/plugin_dirs.lua`.

- **`plugin_dirs.lua` is the single definition of "which plugin directories apply here."** Order
  is fixed at self → `.vibing/plugins/*/` → `agent.plugins.extra`, because the **earlier
  `--plugin-dir` flag wins**.
- **A directory the CLI declines is silently ignored**, so `plugin_dirs` reads each candidate's
  `.claude-plugin/plugin.json` itself and warns about the ones it drops.
- **`.vibing/plugins/` is read by default, and that is a security decision**: a plugin may declare
  `mcpServers`. `agent.plugins.project_dir = false` is the opt-out.
- **`:VibingReloadCommands` clears `plugin_dirs` first**, before the provider caches — both
  re-resolve from it.
- **Not passed on the lightweight path**, per `core/types.lua`.
- **`TERMINAL_ONLY_COMMANDS` is a denylist, not an allowlist**: built-in skills live inside the
  binary, and a stale allowlist would hide a new one.
- **Codex loads the same list, in two halves.** Codex 0.153 has no per-run plugin flag, so
  `adapter/modules/codex_plugin_config.lua` turns each plugin's `mcpServers` into
  `-c mcp_servers.<name>.*` overrides (`default_tools_approval_mode="approve"`, or headless exec
  cancels every call) and lists its `skills/` in `-c developer_instructions`. `agents/` does not
  travel. Server names must be bare TOML keys — the `-c` key path is never unquoted.
  `handbook/architecture/plugin-and-commands.md` → "Codex".
- **`setup()` runs on the user's startup path**, so synchronous I/O there is the cost that
  matters. Custom slash commands are scanned on first use, with the already-loaded guard set
  **before** the scan.

Measurements: `handbook/architecture/plugin-and-commands.md`.

## Module Structure

Layered `domain` / `application` / `infrastructure` / `presentation`, not the flat `actions/` +
`ui/` layout used before v4. The per-directory listing, the key entry points, and what a new
backend still has to write (`new()` and `stream()`, and why `stream()` stayed per-adapter) are in
`handbook/architecture/module-map.md`.

## Session Persistence

Chat files are Markdown with YAML frontmatter (`session_id`, `working_dir`, `model`, `effort`,
`permission_mode`, `permissions_allow` / `_deny`, `language`, `orchestrated` / `orchestrated_by`).
The full field list is `doc/vibing.txt` → "CHAT FILE FORMAT".

- **The key is singular `permission_mode`.** The legacy plural `permissions_mode` is migrated on
  parse (`infrastructure/storage/frontmatter.lua`) so old files keep working, but it is no longer
  completed and must not be written.
- **`effort` is omitted unless configured.** With no `agent.default_effort` vibing.nvim passes no
  flag and the CLI applies its own default; pinning a level would freeze it. An unrecognised level
  is dropped with a warning, because the CLI accepts unknown levels silently and ignores them.
- **`Git.resolve_working_dir` bounds `working_dir` to the git root.** A value resolving outside is
  warned about once and treated as unset (`nil` already means "no chat-specific cwd" at every call
  site), which is what lets `create_chat.lua` reject an out-of-bounds request outright.
  `handbook/architecture/session-persistence.md`.
- **Lightweight calls** (title generation, `/summarize`, `:VibingSummarize`, daily summary) owe
  the obligation stated in `core/types.lua` — no tools, no project config, no user MCP servers, no
  hooks, `utility_model` — not any one backend's mechanism. Grok is the one backend that cannot
  keep the whole bargain. `handbook/architecture/lightweight-calls.md`.

## Per-Request Diffs

Each turn's `### Modified Files` and its `.vibing/patches/*.patch` come from **two git tree
snapshots of the working tree** (`core/utils/git_snapshot.lua`), so a change made by `sed -i`, `mv`
or a formatter run through Bash still shows up (#625).

- **The user's index is never touched.** `git add -A` runs against a copy handed over as
  `GIT_INDEX_FILE`.
- **The baseline is lazy**, taken at the PreToolUse hook for the first tool that could write. The
  trigger is an **exclusion** list, not an allow list: a tool whose name says nothing about its
  behaviour has to count as a writer.
- **`.vibing/` is excluded by pathspec on the diff calls, and only conditionally on `git add -A`**
  — `git add` exits 1 when a pathspec explicitly names an ignored path, including a _negative_
  one, which silently disabled the whole mechanism until #664.
- **The git calls block the main loop** (`vim.system():wait()`): 20ms per `git add -A` on a 9k-file
  tree, 63ms on an 80k one.
- **`request_diff.lua` stays as the fallback**, and a turn where both come up empty **warns**
  rather than rendering as a turn that changed nothing.

`handbook/architecture/per-request-diffs.md`.

## Concurrent Execution, Fork and Subagent Chat

Each chat buffer maintains its own session ID; sessions are keyed by unique handle IDs
(`hrtime + random`).

- **Directory creation is a shared-state operation.** `vim.fn.mkdir(path, "p")` is not atomic and
  raises `E739` when another process wins the race — 9 failures in 200 concurrent calls. Every
  directory creation goes through `core/utils/fs.lua`'s `ensure_dir`, and `fs_spec.lua` **fails
  the build if a direct `vim.fn.mkdir` reappears anywhere in `lua/`**.
- **A fork inherits the source's `session_id`** and marks itself with `forked_from`;
  `opts._is_fork` makes the command builder emit `--fork-session`.
- **A subagent chat shares the parent's `session_id` permanently and must never fork** —
  `--fork-session` makes `SendMessage` fail with `No transcript found for agent ID`. Two buffers
  therefore resume one session, so `send_message.lua` hard-refuses a send while another buffer's
  stream holds it.

`handbook/architecture/chat-lineage.md`.

## Multi-Agent Orchestration

One chat can create and drive others: `nvim_chat_create` (MCP) → `rpc/handlers/chat.lua` →
`application/chat/use_cases/create_chat.lua`. The workflow is the bundled
`claude-plugin/skills/vibing-orchestrate/SKILL.md`; there is no command and no scheduler.

- **The chat file path is the identifier; a bufnr is a per-session resolution of it.**
  `nvim_chat_send_message` and `nvim_get_buffer` take `file_path` or `bufnr` and **refuse a call
  that passes both**. `from_bufnr` stays a bufnr, since it names the calling chat.
- **The relationship is recorded in frontmatter, not in the transcript** — `orchestrated` /
  `orchestrated_by`, kept in step across renames by `link/orchestration_chat_scanner.lua`.
- **An `orchestrated` element is `<path>` or `<path>|<task>` (#696), encoded/decoded only through
  `orchestrated_entry.lua`.** The task an orchestrator gave a chat lives there — on the
  orchestrator's own entry — and nowhere on the driven chat's own frontmatter; `orchestrated_by`
  never carries the suffix. Comparing or replacing an `orchestrated` item as a bare string instead
  of going through `OrchestratedEntry.find`/`encode` silently breaks on any entry that has a task.
- **Completion detection is a status field, not a text heuristic**, and `idle` means "no request
  in flight", **not** "succeeded".
- **Completion is pushed, not polled, and the send is the subscription.** The CLI process dies
  when its turn ends, so the only way to deliver anything to a chat is to start a new turn on it.
- **Reporting is the worker's job; the notification is a watchdog.** `agent.chat_notifications`
  gates only the watchdog — a stop the chat cannot leave on its own (`asked_question`,
  `waiting_approval`, `error`) is delivered whatever the setting is.
- **The report protocol is injected, not left to the brief or to skill auto-trigger** (#706). A
  chat with `orchestrated_by` gets the orchestrator's `file_path` and the report protocol appended
  to its system prompt on every turn (`cli_command_builder.lua`), pointing at the
  `claude-plugin/skills/vibing-worker/SKILL.md` skill for the rest. Skill discovery by description
  match is probabilistic, so this line — not the orchestrator's brief text — is the one place a
  worker is guaranteed to be told where and how to report.
- **A worker's tool-approval prompt is the user's to clear unless the user says otherwise**
  (`agent.orchestration.delegated_approval`, default `false`).
- **A message delivered from another chat gets its own section kind** — `## Request`, `## Report`
  or `## Notice`. `extract_role` still answers `user` for all three.

The notification state machine, the queue, the round-trip budget and the tree operations:
`handbook/architecture/orchestration.md`.

## Git Worktree Integration

Worktrees are plain `git worktree add -b <branch> .vibing/worktrees/<branch>/`, removed with
`git worktree remove`; a worktree's existence on disk is its entire state. There is no lifecycle
script and no metadata file. The chat's `working_dir` frontmatter keeps a conversation attached to
its worktree across turns. The workflow is the bundled `vibing-worktree-*` skills
(`claude-plugin/skills/`), driven by natural language.
