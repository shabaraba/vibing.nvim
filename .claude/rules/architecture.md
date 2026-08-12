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
`rpc/registry.lua` and `mcp-server/src/handlers/instances.ts`).

`hook_cleanup.cleanup_stale_dirs()` (run at startup) treats a comm directory as stale only when
its owning Neovim is gone: it cross-checks `registry.list()`, which already filters to live PIDs,
so a concurrent instance's in-flight `.req`/`.res` files are never deleted.

**Backends:** `claude_cli.lua` (default) and `codex_cli.lua` both implement the adapter
interface; `init.lua` picks one from `config.adapter`, and `send_message.lua` can switch per
request for `codex` agent types. Implementing the interface is not the same as feature parity —
`AskUserQuestion` is Claude-only, for reasons `features.md` records.

## Module Structure

The tree is layered (`domain` / `application` / `infrastructure` / `presentation`), not the flat
`actions/` + `ui/` layout used before v4.

**Core:**

- `lua/vibing/init.lua` - Entry point, command registration, adapter selection
- `lua/vibing/config.lua` - Configuration defaults with type annotations
- `lua/vibing/core/constants/` - `tools.lua` (VALID_TOOLS), `modes.lua`, `worktree.lua`
- `lua/vibing/core/utils/` - timestamp, language, git, mote, rate_limit, request_diff, ...

**Adapter (`lua/vibing/infrastructure/adapter/`):**

- `base.lua` - Abstract adapter interface
- `claude_cli.lua` / `codex_cli.lua` - Backend adapters (spawn + stream lifecycle)
- `modules/cli_command_builder.lua` - Claude CLI argv construction (flags, system prompt)
- `modules/cli_event_processor.lua` - stream-json → chunk/tool events
- `modules/codex_command_builder.lua` / `modules/codex_event_processor.lua` - Codex equivalents
- `modules/session_manager.lua`, `modules/active_stream_registry.lua` - Session/handle tracking

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
- mcp-server/src/index.ts      - MCP server entry point
- mcp-server/src/tools/        - MCP tool implementations (buffer, lsp, window, chat)

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
working_dir: .vibing/worktrees/fix-auth-session # Optional: relative path from git root for working directory
model: sonnet # sonnet, opus, haiku, or fable (from config.agent.default_model)
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
via `/model` slash command. Configured permissions are recorded in frontmatter for
transparency and auditability. The optional `language` field ensures consistent AI response language
across sessions.

Note the singular `permission_mode`: that is the key `send_message.lua` actually reads, the key
completion offers, and the key the serializer orders. The legacy plural `permissions_mode` is
migrated to the singular form on parse (`infrastructure/storage/frontmatter.lua`) so old chat
files keep working, but it is no longer completed and should not be written.

**Working directory persistence:** The `working_dir` field stores the working directory as a relative
path from git root (e.g., `.vibing/worktrees/<branch>`). When a chat is reopened, the agent
and mote commands are executed in this directory. This ensures consistent file operations across
sessions, even when using a worktree or a custom directory.

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

See `docs/adr/002-concurrent-execution-support.md` for architectural details.

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
(`skills/vibing-worktree-*`), not through a vibing.nvim chat command. There is no bespoke
lifecycle script or metadata file — worktrees are created with plain
`git worktree add -b <branch> .vibing/worktrees/<branch>/` and removed with
`git worktree remove`; a worktree's existence on disk is its entire state. The chat's own
`working_dir` frontmatter field (unchanged by this) is what keeps a conversation attached to its
worktree across turns. See `skills/vibing-worktree-list/SKILL.md` (and its sibling `-create`,
`-attach`, `-run`, `-finish` skills) for the full list/create/attach/finish workflow.
