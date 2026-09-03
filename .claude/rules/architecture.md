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

The rest of the hook contract — the comm directory, the atomic `.req` rename, the `nc`
fail-closed path, the 120s poll, and the stale-directory sweep — is in
`handbook/architecture/cli-integration.md`. Three invariants from it apply whenever this path is
touched:

- **The hook fails closed.** If `nc` cannot connect or no response arrives, it exits 2 and the
  tool is denied. Do not add a path that exits 0 on an internal failure.
- **The `.res` file carries three decisions, not two** — `deny`, `allow` and `defer`. Exiting 0
  in silence is `defer` ("no opinion"), _not_ an approval.
- **Only vibing-nvim's own MCP tools get `allow`; everything else permitted gets `defer`.**
  An `allow` skips the CLI's own gate, and with it the user's `settings.json` deny rules, which
  `--setting-sources user,project,local` still pulls in.

The comm directory path has exactly one definition, `infrastructure/rpc/comm_dir.lua`, shared by
the handlers, the cleanup routine and `bin/hooks/*.sh`.

**Backends:** `claude_cli.lua` (default), `codex_cli.lua`, `copilot_cli.lua` and `grok_cli.lua`
implement the adapter interface; `init.lua` picks one from `config.adapter`, and `send_message.lua` can switch
per request for non-claude agent types. Implementing the interface is not the same as feature
parity — `AskUserQuestion` is Claude-only, for reasons `features.md` records.

`lua/vibing/core/constants/agents.lua` is the single definition of what a backend is — module
path, export name, description, model candidates. `factory.lua`, `modes.lua` (`VALID_AGENTS`,
`VALID_MODELS`), `completion/providers/frontmatter.lua` and `infrastructure/init.lua` all derive
from it, so adding a backend is a one-file change (grok was added that way). It deliberately requires nothing, which
is what keeps the dependency one-way.

Several seams stop backend identity from leaking into shared code. The rule they encode:
**a backend name belongs in that backend's own module, and shared code takes what it is handed.**

`bin/hooks/pre-tool-use.sh` is the one deliberate exception: what varies there is not only the
JSON shape but the deny _signalling_ convention — claude denies with exit 2 + stderr, copilot with
exit 0 + stdout — and that is shell semantics, so it lives in the shell.

Each adapter owns a `<backend>_tool_vocabulary.lua` offering up to three normalizations, and
**their order is load-bearing**: `normalize_payload` (the payload's own key names) must run before
`to_canonical` (the tool's name) and `normalize_input` (where the path lives in the input), or the
two later steps get nothing to work on, every rule misses, and the turn stalls until the hook
fails closed. `rpc/handlers/permission.lua` just calls whichever the module offers and contains no
backend name.

Two backends need more than a vocabulary, and both facts change what you may assume: **grok
discovers project hooks only inside a git repository** (outside one the gate would silently allow
everything, so `ensure()` warns instead), and **copilot's hook is injected as a throwaway plugin**
under `.vibing/copilot-plugin/` via `--plugin-dir`, with a schema that is not claude's.

Why each seam exists, which CLI version each shape was captured from, and the three copilot
details that silently disable the gate if got wrong:
`handbook/architecture/cli-integration.md` → "Backend Seams".

## Plugin Loading, Command Discovery and Startup Cost

vibing.nvim's own Claude Code plugin — the `vibing-nvim` MCP server, the bundled skills, the
`nvim-navigator` agent — is **not installed**. `cli_command_builder` passes `--plugin-dir <path>`
once per directory resolved by `infrastructure/plugins/plugin_dirs.lua`, which loads a plugin for
that CLI invocation only and writes nothing to Claude Code's global state.

- **`plugin_dirs.lua` is the single definition of "which plugin directories apply here."** The
  argv, the skill completion provider and the agent completion provider all read it rather than
  re-deriving the convention. The order is fixed at self → `.vibing/plugins/*/` →
  `agent.plugins.extra`, because the CLI's **earlier `--plugin-dir` flag wins**.
- **A directory the CLI declines is silently ignored** — exit 0, no warning — so `plugin_dirs`
  reads each candidate's `.claude-plugin/plugin.json` itself and warns about the ones it drops.
- **`.vibing/plugins/` is read by default, and that is a security decision.** A plugin may declare
  `mcpServers`, so a directory committed to a cloned repository can start a process on the user's
  machine on the first message. `agent.plugins.project_dir = false` is the opt-out.
- **`:VibingReloadCommands` clears `plugin_dirs` first**, before the provider caches: both
  re-resolve from it, so clearing it second refills them from the list being discarded.
- **Not passed on the lightweight path**, per `core/types.lua`.
- **Codex loads the same list, in two halves.** Codex 0.153 has no per-run plugin flag, so
  `adapter/modules/codex_plugin_config.lua` turns each plugin's `mcpServers` into
  `-c mcp_servers.<name>.*` overrides (`default_tools_approval_mode="approve"`, or headless exec
  cancels every call) and lists its `skills/` in `-c developer_instructions`. `agents/` does not
  travel. Server names must be bare TOML keys — the `-c` key path is never unquoted. Details and
  the measurements: `handbook/architecture/plugin-and-commands.md` → "Codex".
- **The `/` menu's skills come from the CLI, not the filesystem** — built-in skills live inside
  the binary. `completion/cli_command_list.lua` asks it once per working directory. What is
  hand-maintained is `TERMINAL_ONLY_COMMANDS`, a **deny**list: a stale allowlist hides a new
  skill, a stale denylist shows one extra entry.
- **`setup()` runs on the user's startup path**, so synchronous I/O there is the cost that
  matters, not the module tree (~9ms of it). Custom slash commands are scanned on first use, with
  the already-loaded guard set **before** the scan so a scan finding nothing does not retry.

The measurements behind all of it — what `--plugin-dir` does with a duplicate plugin name, why
the probe passes `--strict-mcp-config`, and what `build.sh` used to do instead — are in
`handbook/architecture/plugin-and-commands.md`.

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

**Lightweight calls** (title generation, `/summarize`, `:VibingSummarize`, daily summary) are
restricted differently per backend, because the four CLIs differ in kind rather than in degree.
`core/types.lua` states the obligation each adapter owes — no tools, no project config, no user
MCP servers, no hooks, `utility_model` — rather than the mechanism any one of them uses. Claude
removes the tools outright (`--tools ""`); codex can only fence them in with a read-only sandbox
plus `--ignore-user-config --strict-config`; copilot names a sentinel in `--available-tools`;
grok names one real harmless tool, because an unmappable entry makes it discard the whole
restriction. Grok is the one backend that cannot keep the whole bargain.

Each mechanism, the probes that established it, and what silently stops working if a flag lapses:
`handbook/architecture/lightweight-calls.md`.

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

How the boundary is computed — and why `fnamemodify(":p")` cannot do the job while
`vim.fn.resolve()` can, and why both sides of the comparison must be physical paths:
`handbook/architecture/session-persistence.md`.

## Per-Request Diffs

Each turn's `### Modified Files` list and its `.vibing/patches/*.patch` come from **two git tree
snapshots of the working tree** (`core/utils/git_snapshot.lua`), taken before and after the turn
and compared with `git diff`. The point of that shape is what it does _not_ need to know: which
tool made the change — so a `sed -i`, a `mv` or a formatter run through Bash shows up, where the
mechanism it replaced saw nothing (#625).

Invariants for anything touching this path:

- **The user's index is never touched.** `git add -A` runs against a copy of the real index handed
  over as `GIT_INDEX_FILE`, so it cannot collide with a `git commit` the user runs mid-turn.
- **The baseline is lazy** — taken at the PreToolUse hook for the first tool that could write, so
  a read-only turn takes no snapshot. The trigger is an **exclusion** list, not an allow list: a
  tool whose name says nothing about its behaviour has to count as a writer.
- **`.vibing/` is excluded by pathspec on the diff calls, and only conditionally on `git add -A`.**
  `git add` exits 1 when a pathspec explicitly names an ignored path — including a _negative_
  pathspec — which silently disabled the whole mechanism until #664.
- **The git calls block the main loop** (`vim.system():wait()`), measured at 20ms per `git add -A`
  on a 9k-file tree and 63ms on an 80k one.
- **`request_diff.lua` stays as the fallback** for a non-git `working_dir`, an overlapping turn,
  and an unreadable snapshot. Its backups are dropped only once the snapshot path has actually
  produced output, and a turn where both come up empty **warns** rather than rendering as a turn
  that changed nothing.

The overlap guard, the ref namespace and its two-guard sweep, the untracked-file trade, and the
full fallback routing table: `handbook/architecture/per-request-diffs.md`.

## Concurrent Execution, Chat Fork and Subagent Chat

Each chat buffer maintains its own session ID; sessions are managed via unique handle IDs
(`hrtime + random`) and stale ones are cleaned up when new messages start. See
`handbook/adr/002-concurrent-execution-support.md`.

- **Directory creation is a shared-state operation.** `vim.fn.mkdir(path, "p")` is not atomic and
  raises `E739` when another process creates a component first — measured at 9 failures in 200
  concurrent calls. Every directory creation goes through `core/utils/fs.lua`'s `ensure_dir`, and
  `fs_spec.lua` **fails the build if a direct `vim.fn.mkdir` reappears anywhere in `lua/`**. It
  retries rather than catch-and-recheck, and re-raises everything that is not the race.
- **A fork inherits the source's `session_id`** and marks itself with `forked_from`;
  `opts._is_fork` makes the command builder emit `--fork-session`. After the first response
  `session_id` is updated and `forked_from` cleared.
- **A subagent chat shares the parent's `session_id` permanently and must never fork** — a
  subagent's transcript lives under the parent session's directory, and `--fork-session` makes
  `SendMessage` fail with `No transcript found for agent ID`. Two buffers therefore resume one
  session, so `send_message.lua` hard-refuses a send while another buffer's stream holds it.

Why each of those is the only workable shape: `handbook/architecture/chat-lineage.md`.

## Multi-Agent Orchestration

One chat can create and drive other chats: `nvim_chat_create` (MCP) →
`infrastructure/rpc/handlers/chat.lua` → `application/chat/use_cases/create_chat.lua` →
`view.render`. The workflow is the bundled `claude-plugin/skills/vibing-orchestrate/SKILL.md`;
there is no command and no scheduler.

- **The chat file path is the identifier; the bufnr is a per-session resolution of it.** A bufnr
  means nothing in a Neovim other than the one that issued it. `nvim_chat_send_message` and
  `nvim_get_buffer` take `file_path` or `bufnr`, open a chat that is closed, and **refuse a call
  that passes both**. `from_bufnr` stays a bufnr, since it names the calling chat.
- **The relationship is recorded in frontmatter, not in the transcript** — `orchestrated` /
  `orchestrated_by`, kept in step across renames by
  `infrastructure/link/orchestration_chat_scanner.lua`.
- **Completion detection is a status field, not a text heuristic.** `nvim_get_buffer` reports
  `responding` / `idle` / `waiting_approval` / `asked_question` / `error`. `idle` means "no
  request in flight", **not** "succeeded".
- **Completion is pushed, not polled, and the send is the subscription.** There is no waiting
  anywhere: the CLI process dies when its turn ends, so the only way to deliver anything to a
  chat is to start a new turn on it.
- **Reporting is the worker's job; the notification is a watchdog.** `agent.chat_notifications`
  gates only the watchdog — a stop the chat cannot leave on its own (`asked_question`,
  `waiting_approval`, `error`) is delivered whatever the setting is.
- **A message delivered from another chat gets its own section kind** — `## Request`, `## Report`
  or `## Notice`. `extract_role` still answers `user` for all three; only the display splits.

The notification state machine is the long part — the three branches of `on_response_done`, the
one-shot edges, the suppression mark, the per-pair round-trip budget, the message queue, tree
operations and the concurrency cap. All of it, with the failure each rule prevents:
`handbook/architecture/orchestration.md`.

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
