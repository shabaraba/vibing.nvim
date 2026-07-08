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
working_dir: .vibing/workspace/0001-feature-branch/worktree # Optional: relative path from git root for working directory
model: sonnet # sonnet, opus, or haiku (from config.agent.default_model)
permissions_mode: acceptEdits # default, acceptEdits, bypassPermissions, plan, or dontAsk
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

**Working directory persistence:** The `working_dir` field stores the working directory as a relative
path from git root (e.g., `.vibing/workspace/<id>/worktree`). When a chat is reopened, the agent
and mote commands are executed in this directory. This ensures consistent file operations across
sessions, even when using workspace or custom directories.

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

## Chat Fork

`:VibingChatFork` creates a branched conversation from the current chat session.

**Session Lifecycle:**

```text
Source Chat (session-abc)
  │
  ├─ User sends messages... SDK uses session-abc
  │
  └─ :VibingChatFork right
       │
       Fork Chat (session_id: session-abc, forked_from: source.md)
         │
         ├─ First message → SDK: query({ resume: session-abc, forkSession: true })
         │                  → SDK returns new session-def
         │                  → frontmatter updated: session_id: session-def
         │                  → forked_from cleared
         │
         └─ Subsequent messages → SDK uses session-def independently
```

**Key Design Decisions:**

- Fork inherits the source's `session_id` directly in frontmatter (no separate side-channel)
- The `forked_from` frontmatter field indicates a pending fork; `--fork-session` boolean flag is sent to the SDK
- After the first response, `forked_from` is cleared and `session_id` is updated to the new value
- This avoids `BufReadPost`/`attach_to_buffer` lifecycle issues where in-memory state would be lost
- `ForkedChatScanner` automatically updates `forked_from` links when source files are renamed

**Implementation:**

- `lua/vibing/application/chat/use_cases/fork.lua` - Fork use case
- `lua/vibing/infrastructure/link/forked_chat_scanner.lua` - Link synchronization scanner
- `bin/agent-wrapper.ts` - `--fork-session` flag handling

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

## Git Worktree Integration

Worktree-backed development goes through the `vibing-workspace-*` Claude Code skills bundled
with this plugin (`skills/vibing-workspace-create`, `-enter`, `-done`, `-list`), not through a
vibing.nvim chat command. Workspace directories, including the git worktree itself, live under
`.vibing/workspace/<id>/` (a workspace is "done" once its `worktree/` subdirectory has been
removed). See `skills/vibing-workspace/SKILL.md` for the shared
directory layout and `meta.yaml` schema, and `scripts/vibing-workspace.mjs` for the bundled
script that manages workspace creation/removal.
