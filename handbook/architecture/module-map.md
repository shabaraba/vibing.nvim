# Module Map and Key Entry Points

Moved out of `.claude/rules/architecture.md`. The always-loaded rules keep the layering and the
seams; this file is the directory listing, which is re-derivable from the tree and so does not
need to be in every request.

The tree is layered (`domain` / `application` / `infrastructure` / `presentation`), not the flat
`actions/` + `ui/` layout used before v4.

## Core

- `lua/vibing/init.lua` - Entry point, command registration, adapter selection
- `lua/vibing/config.lua` - Configuration defaults with type annotations
- `lua/vibing/core/constants/` - `agents.lua` (backend registry), `tools.lua` (VALID_TOOLS),
  `modes.lua`, `worktree.lua`
- `lua/vibing/core/utils/` - timestamp, language, git, git_snapshot, rate_limit, request_diff, ...

## Adapter (`lua/vibing/infrastructure/adapter/`)

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

## Chat (presentation + application)

- `presentation/chat/buffer.lua`, `view.lua`, `controller.lua` - Chat buffer and window
- `presentation/chat/modules/` - renderer, streaming_handler, frontmatter_handler, file_manager,
  approval_parser, keymap_handler, ...
- `application/chat/send_message.lua` - Request orchestration (opts, callbacks, diffs)
- `application/chat/use_cases/fork.lua` - Chat fork
- `application/chat/use_cases/handoff.lua` - Summary-carrying new chat (`:VibingChatHandoff`)
- `application/chat/auto_resume.lua` - Usage-limit auto-resume scheduler

## RPC / hooks

- `infrastructure/rpc/server.lua` - Async TCP server queried by hooks and the MCP server
- `infrastructure/rpc/handlers/permission.lua` - PreToolUse decisions, approval UI,
  `ask_user_question`
- `infrastructure/rpc/handlers/rate_limit.lua` - StopFailure receiver
- `infrastructure/hooks/settings_generator.lua` - Writes `.vibing/hook-settings.json`

## Context System

- `application/context/manager.lua` - Context manager (manual + auto from open buffers)
- `infrastructure/context/collector.lua` - Collects `@file:path` formatted contexts

## UI

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

## Key Patterns

**Adapter Pattern:** All AI backends implement the `Adapter` interface with `execute()`,
`stream()`, `cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration,
automatically updating chat frontmatter without manual YAML editing.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a
vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language for chat, supporting multi-language
development workflows.
