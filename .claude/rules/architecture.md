# Architecture

## Communication Flow

```text
Neovim (Lua) → vim.system() → Node.js wrapper → Claude Agent SDK
                    ↑
            JSON Lines protocol
```

The Node.js wrapper (`bin/agent-wrapper.mjs`) outputs streaming responses as JSON Lines:

- `{"type": "session", "session_id": "..."}` - Session identifier for resumption
- `{"type": "chunk", "text": "..."}` - Streamed text content
- `{"type": "tool_use", "tool": "Edit", "file_path": "..."}` - File modification event
- `{"type": "done"}` - Completion signal
- `{"type": "error", "message": "..."}` - Error messages

## Module Structure

**Core:**

- `lua/vibing/init.lua` - Entry point, command registration
- `lua/vibing/config.lua` - Configuration with type annotations

**Adapter:**

- `adapters/base.lua` - Abstract adapter interface
- `adapters/agent_sdk.lua` - Claude Agent SDK adapter (only supported backend)

**UI:**

- `ui/chat_buffer.lua` - Chat window with Markdown rendering, session persistence, diff viewer
- `ui/output_buffer.lua` - Read-only output for inline actions
- `ui/inline_progress.lua` - Progress window for inline code modifications
- `ui/permission_builder.lua` - Interactive permission configuration UI

**Context System:**

- `context/init.lua` - Context manager (manual + auto from open buffers)
- `context/collector.lua` - Collects `@file:path` formatted contexts

**Actions:**

- `actions/chat.lua` - Chat session orchestration with concurrent session support
- `actions/inline.lua` - Quick actions (fix, feat, explain, refactor, test) with queue management

**Infrastructure:**

- `infrastructure/worktree/manager.lua` - Git worktree management (create, check existence, environment setup)

## Key Entry Points

Quick reference for commonly edited files:

```text
Lua Plugin:
- lua/vibing/init.lua          - Plugin initialization and commands
- lua/vibing/config.lua        - Configuration schema and defaults
- lua/vibing/adapters/agent_sdk.lua - Agent SDK adapter implementation
- lua/vibing/ui/chat_buffer.lua     - Chat window implementation
- lua/vibing/actions/chat.lua       - Chat session orchestration

Node.js Backend:
- bin/agent-wrapper.ts         - Agent SDK wrapper entry point
- mcp-server/src/index.ts      - MCP server entry point
- mcp-server/src/tools/        - MCP tool implementations (buffer, lsp, window)

Tests:
- tests/*_spec.lua             - Lua tests (plenary.nvim)
- tests/*.test.mjs             - Node.js tests
```

## Session Persistence

Chat files are saved as Markdown with YAML frontmatter:

```yaml
---
vibing.nvim: true
session_id: <sdk-session-id>
created_at: 2024-01-01T12:00:00
mode: code # auto, plan, code, or explore (from config.agent.default_mode)
model: sonnet # sonnet, opus, or haiku (from config.agent.default_model)
permissions_mode: acceptEdits # default, acceptEdits, or bypassPermissions
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
`session_id`. The `mode` and `model` fields are automatically populated from
`config.agent.default_mode` and `config.agent.default_model` on chat creation, and can be changed
via `/mode` and `/model` slash commands. Configured permissions are recorded in frontmatter for
transparency and auditability. The optional `language` field ensures consistent AI response language
across sessions.

**Note on worktree sessions:** When using `:VibingChatWorktree`, the working directory (cwd) is set
in memory only and not saved to frontmatter. This prevents issues when reopening chat files after
worktree deletion. The cwd is only active during the initial VibingChatWorktree session.

## Concurrent Execution Support

vibing.nvim supports running multiple chat sessions and inline actions simultaneously without interference:

**Multiple Chat Windows:**

- Each chat buffer maintains its own session ID
- Sessions are managed via unique handle IDs
- Old sessions are automatically cleaned up when starting new messages

**Inline Action Queue:**

- Multiple inline actions are queued and executed serially
- Prevents file modification conflicts
- Shows queue notifications (e.g., "Executing task (2 more in queue)...")
- Errors in one task don't block subsequent tasks

**Session Management:**

- Handle IDs: `hrtime + random` ensures uniqueness across concurrent requests
- Session lifecycle: Created → Used → Automatically cleaned up when stale
- `cleanup_stale_sessions()` removes completed sessions while preserving active ones

**Example Workflow:**

```lua
-- Start multiple chats simultaneously
:VibingChat  -- Chat 1 (session-abc)
:VibingChat  -- Chat 2 (session-def)

-- Queue multiple inline actions
:'<,'>VibingInline fix      -- Queued: task 1
:'<,'>VibingInline refactor -- Queued: task 2 (waits for task 1)
```

See `docs/adr/002-concurrent-execution-support.md` for architectural details.

## Key Patterns

**Adapter Pattern:** All AI backends implement the `Adapter` interface with `execute()`, `stream()`,
`cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration,
automatically updating chat frontmatter without manual YAML editing.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a
vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language globally or per-action (chat vs inline),
supporting multi-language development workflows.

**Git Worktree Integration:** Create isolated development environments for different branches with
`:VibingChatWorktree`. Each worktree maintains its own chat history while sharing the same
git repository. The system automatically:

- Creates worktrees in `.worktrees/<branch-name>` directory
- Copies essential configuration files (`.gitignore`, `package.json`, `tsconfig.json`, etc.)
- Symlinks `node_modules` from the main worktree to avoid duplicate installations
- Reuses existing worktrees without recreating the environment
- Saves chat files in main repository at `.vibing/worktrees/<branch-name>/` (persists after worktree deletion)
