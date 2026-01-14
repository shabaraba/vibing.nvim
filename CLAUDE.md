# CLAUDE.md

This file provides guidelines for Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

vibing.nvim is a Neovim plugin that integrates Claude AI through the Agent SDK.
It provides chat and inline code actions within Neovim.

## Commands

```bash
# Install dependencies
npm install

# Build TypeScript to JavaScript (production mode)
npm run build

# Test Agent SDK wrapper directly
node dist/bin/agent-wrapper.js --prompt "Say hello" --cwd $(pwd)
```

For Neovim testing, load the plugin and run `:VibingChat`.

### Development Mode

vibing.nvim supports two execution modes:

**Production Mode (default):**

- Uses compiled JavaScript from `dist/bin/agent-wrapper.js`
- Requires `npm run build` after code changes
- Faster startup time

**Development Mode:**

- Directly executes TypeScript from `bin/agent-wrapper.ts` using bun
- No build step required - changes take effect immediately
- Requires bun to be installed in PATH

**Enable via Lazy.nvim (recommended):**

```lua
return {
  "yourusername/vibing.nvim",
  dev = true,  -- Automatically enables dev_mode
  dir = "~/workspaces/nvim-plugins/vibing.nvim",
  config = function()
    require("vibing").setup({
      -- node.dev_mode is automatically set to true when dev = true
    })
  end,
}
```

**Manual enable:**

```lua
require("vibing").setup({
  node = {
    dev_mode = true,  -- Enable TypeScript direct execution with bun
  },
})
```

## Developing vibing.nvim with vibing.nvim

When you (Claude Agent SDK) are working on vibing.nvim itself, follow these guidelines to leverage vibing.nvim's built-in workflows:

### Preferred Workflows

**For Feature Development:**
1. Use `:VibingChatWorktree <branch-name>` instead of manual `git worktree` commands
   - Automatically creates isolated development environment
   - Copies essential configs (`.gitignore`, `package.json`, `tsconfig.json`)
   - Symlinks `node_modules` to avoid duplicate installations
   - Saves chat files in main repo at `.vibing/worktrees/<branch>/`

**For Buffer/Window Operations:**
1. Use vibing.nvim MCP tools (`mcp__vibing-nvim__*`) instead of generic file operations
   - `mcp__vibing-nvim__nvim_get_buffer` - Read buffer content
   - `mcp__vibing-nvim__nvim_set_buffer` - Write buffer content
   - `mcp__vibing-nvim__nvim_list_windows` - List all windows
   - `mcp__vibing-nvim__nvim_load_buffer` - Load file in background (no window switching)
   - See "MCP Integration" section for full list

**For LSP Operations:**
1. ALWAYS use vibing-nvim LSP tools, NOT Serena or other generic LSP tools
   - vibing-nvim tools connect to the RUNNING Neovim instance with active LSP servers
   - Other tools analyze separate file copies and miss runtime state

**For Context Management:**
1. Use `:VibingContext <file>` to add files to context
2. Use `:VibingClearContext` to clear context

### Example Development Workflow

```typescript
// ✅ CORRECT - vibing.nvim-aware workflow
// 1. Create worktree for new feature
await use_mcp_tool("vibing-nvim", "nvim_execute", {
  command: "VibingChatWorktree right feature-new-ui"
});

// 2. Load file in background for LSP analysis
const { bufnr } = await use_mcp_tool("vibing-nvim", "nvim_load_buffer", {
  filepath: "lua/vibing/ui/chat_buffer.lua",
  rpc_port: process.env.VIBING_NVIM_RPC_PORT
});

// 3. Use LSP to find references
const refs = await use_mcp_tool("vibing-nvim", "nvim_lsp_references", {
  bufnr: bufnr,
  line: 100,
  col: 5,
  rpc_port: process.env.VIBING_NVIM_RPC_PORT
});

// 4. Make changes via Edit tool
// ... (Agent SDK's Edit tool)

// 5. Build and test
await use_mcp_tool("vibing-nvim", "nvim_execute", {
  command: "!npm run build && npm test"
});
```

```typescript
// ❌ WRONG - Generic workflow
// 1. Manual git worktree (misses vibing.nvim setup)
await bash("git worktree add .worktrees/feature-new-ui");

// 2. Use Serena LSP tools (analyzes stale file copies)
const refs = await use_mcp_tool("serena", "lsp_references", { ... });

// 3. Edit files without Neovim awareness
// (may conflict with open buffers)
```

### Environment Variables

When vibing.nvim is running, these environment variables are set:
- `VIBING_NVIM_CONTEXT=true` - Indicates you're running inside vibing.nvim
- `VIBING_NVIM_RPC_PORT=<port>` - RPC port for this Neovim instance (always pass to MCP tools)

Always check and use these variables in your workflows.

## Architecture

### Communication Flow

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

### MCP Integration (Model Context Protocol)

vibing.nvim provides MCP server integration that enables Claude Code to interact with a running
Neovim instance without deadlocks. The architecture uses an async RPC server to avoid blocking
issues.

### User MCP Servers, Slash Commands, Skills, and Subagents

**IMPORTANT:** vibing.nvim's Agent SDK wrapper (`bin/agent-wrapper.mjs`) automatically loads user and project
settings via `settingSources: ['user', 'project']`. This means:

- ✅ **User's custom MCP servers** from `~/.claude.json` are available
- ✅ **Project slash commands** from `.claude/commands/` work out of the box
- ✅ **Project and user skills** from `.claude/skills/` can be invoked
- ✅ **User's global settings and subagents** are inherited

You can use ALL your existing Claude Code configuration and tools within vibing.nvim sessions
without any additional configuration. The vibing-nvim MCP server is automatically registered as
a user-level MCP server during the build process (`build.sh`).

**Architecture:**

```text
┌─────────────────────────────────────────────────────────┐
│ Neovim Process                                           │
│  ├─ RPC Server (lua/vibing/rpc_server.lua)              │
│  │   └─ vim.loop async TCP server (port 9876)           │
│  │       - Non-blocking I/O via libuv                    │
│  │       - vim.schedule() for safe API calls             │
│  │                                                        │
│  └─ Claude Code (subprocess)                             │
│       └─ MCP Server (mcp-server/)                        │
│            └─ TCP client → Neovim RPC server             │
│                 └─ JSON-RPC protocol                     │
└─────────────────────────────────────────────────────────┘
```

**Key Benefits:**

- **No Deadlocks**: Neovim's RPC server uses async I/O (libuv), never blocks
- **Safe API Access**: `vim.schedule()` ensures API calls run on main event loop
- **Bidirectional**: MCP server can both read and write Neovim buffers

**Available MCP Tools:**

When using these tools from Claude Code, prefix them with `mcp__vibing-nvim__`:

**Buffer Operations:**

- `mcp__vibing-nvim__nvim_get_buffer` - Get current buffer content
- `mcp__vibing-nvim__nvim_set_buffer` - Replace buffer content
- `mcp__vibing-nvim__nvim_list_buffers` - List all loaded buffers
- `mcp__vibing-nvim__nvim_get_info` - Get current file information

**Cursor & Selection:**

- `mcp__vibing-nvim__nvim_get_cursor` - Get cursor position
- `mcp__vibing-nvim__nvim_set_cursor` - Set cursor position
- `mcp__vibing-nvim__nvim_get_visual_selection` - Get visual selection

**Window/Pane Operations:**

- `mcp__vibing-nvim__nvim_list_windows` - List all windows with properties (buffer, size, position, focus)
- `mcp__vibing-nvim__nvim_get_window_info` - Get detailed window information
- `mcp__vibing-nvim__nvim_get_window_view` - Get viewport info (visible lines, scroll position)
- `mcp__vibing-nvim__nvim_list_tabpages` - List tab pages with their windows
- `mcp__vibing-nvim__nvim_set_window_size` - Resize window width/height
- `mcp__vibing-nvim__nvim_focus_window` - Move focus to a specific window
- `mcp__vibing-nvim__nvim_win_set_buf` - Set an existing buffer in a specific window
- `mcp__vibing-nvim__nvim_win_open_file` - Open a file in a specific window without switching focus

**IMPORTANT - Window Identification:**

- `nvim_get_window_info({ winnr: 0 })` returns info for the **currently active window** (where focus is), NOT the window where the cursor is visually located
- `nvim_list_windows()` returns all windows and indicates which one is active via `is_current: true`
- When working with specific windows (e.g., resizing chat window), always use `nvim_list_windows()` first to find the correct window by matching buffer name or other properties, then use the `winnr` from the result
- In vibing.nvim chat context, the chat window may not be the active window when the request is sent, so always identify the target window explicitly

**Commands:**

- `mcp__vibing-nvim__nvim_execute` - Execute Neovim commands

**LSP Operations:**

- `mcp__vibing-nvim__nvim_lsp_definition` - Get definition location(s) of symbol
- `mcp__vibing-nvim__nvim_lsp_references` - Get all references to symbol
- `mcp__vibing-nvim__nvim_lsp_hover` - Get hover information (type, documentation)
- `mcp__vibing-nvim__nvim_diagnostics` - Get diagnostics (errors, warnings)
- `mcp__vibing-nvim__nvim_lsp_document_symbols` - Get all symbols in document
- `mcp__vibing-nvim__nvim_lsp_type_definition` - Get type definition location(s)
- `mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming` - Get incoming calls (callers)
- `mcp__vibing-nvim__nvim_lsp_call_hierarchy_outgoing` - Get outgoing calls (callees)

**Background LSP Analysis Workflow:**

All LSP tools work with ANY loaded buffer, not just the active one. This enables background code
analysis without disrupting your current work (e.g., staying in chat while analyzing files).

**Simplified workflow (recommended):**

```javascript
// 1. Load file into buffer without displaying it
const { bufnr } = await use_mcp_tool('vibing-nvim', 'nvim_load_buffer', {
  filepath: 'src/logger.ts',
});

// 2. Analyze in background (no display disruption!)
const calls = await use_mcp_tool('vibing-nvim', 'nvim_lsp_call_hierarchy_incoming', {
  bufnr: bufnr,
  line: 2,
  col: 4,
});
// You're still in chat, got LSP data without any window switching!
```

**Legacy workflow (for reference):**

```javascript
// 1. Load file into buffer (temporarily switches to file)
await use_mcp_tool('vibing-nvim', 'nvim_execute', { command: 'edit src/logger.ts' });

// 2. Get buffer number (now assigned to logger.ts)
const info = await use_mcp_tool('vibing-nvim', 'nvim_get_info', {});
const loggerBufnr = info.bufnr;

// 3. Return to previous buffer (e.g., chat)
await use_mcp_tool('vibing-nvim', 'nvim_execute', { command: 'bprevious' });

// 4. Analyze logger.ts in background (no need to display it)
const calls = await use_mcp_tool('vibing-nvim', 'nvim_lsp_call_hierarchy_incoming', {
  bufnr: loggerBufnr,
  line: 2,
  col: 4,
});
// You're still in chat, but got LSP data from logger.ts!
```

**Key Points:**

- Files must be loaded into buffers for LSP analysis (use `:edit` or similar)
- Once loaded, buffers remain in memory even when not displayed
- Specify `bufnr` parameter to analyze non-active buffers
- Use `:bprevious` or `:buffer <bufnr>` to return to your original work
- LSP server continues analyzing all loaded buffers in background

**Example Usage:**

```javascript
// List all buffers
const buffers = await use_mcp_tool('vibing-nvim', 'nvim_list_buffers', {});

// Get current buffer content
const content = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {});

// ✅ CORRECT: Find specific window and resize it
// Step 1: List all windows to find the target window
const windows = await use_mcp_tool('vibing-nvim', 'nvim_list_windows', {});

// Step 2: Find the window you want (e.g., chat window with .vibing file)
const chatWindow = windows.find((w) => w.buffer_name.endsWith('.vibing'));

// Step 3: Resize using the correct winnr
if (chatWindow) {
  await use_mcp_tool('vibing-nvim', 'nvim_set_window_size', {
    winnr: chatWindow.winnr,
    width: 120,
    height: 30,
  });
}

// ❌ WRONG: Using winnr: 0 may target wrong window
// This targets the currently active window, which may not be the one you want
await use_mcp_tool('vibing-nvim', 'nvim_set_window_size', {
  winnr: 0, // This is the active window, not necessarily the visible one!
  width: 120,
});

// Get detailed info for current window
const winInfo = await use_mcp_tool('vibing-nvim', 'nvim_get_window_info', { winnr: 0 });

// Get viewport information (visible lines)
const viewport = await use_mcp_tool('vibing-nvim', 'nvim_get_window_view', { winnr: 0 });

// Focus a specific window
await use_mcp_tool('vibing-nvim', 'nvim_focus_window', { winnr: 1000 });

// Open file in a specific window without switching focus
await use_mcp_tool('vibing-nvim', 'nvim_win_open_file', {
  winnr: 1000,
  filepath: '/path/to/file.txt',
});

// Set buffer in a specific window
await use_mcp_tool('vibing-nvim', 'nvim_win_set_buf', {
  winnr: 1000,
  bufnr: 5,
});

// Execute command
await use_mcp_tool('vibing-nvim', 'nvim_execute', { command: 'write' });
```

**Quick Setup (Lazy.nvim):**

```lua
return {
  {
    "yourusername/vibing.nvim",
    -- Auto-build MCP server on install/update
    -- This automatically registers vibing-nvim MCP in ~/.claude.json
    build = "./build.sh",  -- Shell script (recommended)
    -- OR
    -- build = function() require("vibing.install").build() end,  -- Lua function
    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          rpc_port = 9876,
          auto_setup = true,  -- Auto-build if not built
          auto_configure_claude_json = false,  -- Deprecated: build.sh now handles registration automatically
        },
      })
    end,
  },
}
```

**NOTE:** The `build` script now automatically registers the vibing-nvim MCP server in
`~/.claude.json`, so manual configuration is typically not needed.

**Manual Configuration:**

Enable MCP integration in your vibing.nvim config:

```lua
require("vibing").setup({
  mcp = {
    enabled = true,
    rpc_port = 9876,
    auto_setup = false,
    auto_configure_claude_json = false,
  },
})
```

The `build` script automatically registers the vibing-nvim MCP server in `~/.claude.json`.
If needed, you can manually add or verify the configuration in `~/.claude.json`:

```json
{
  "mcpServers": {
    "vibing-nvim": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": {
        "VIBING_RPC_PORT": "9876"
      }
    }
  }
}
```

See `mcp-server/README.md` and `docs/lazy-setup-example.lua` for detailed setup instructions.

### Concurrent Execution Support

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

### Module Structure

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

### Session Persistence

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

**Note on worktree sessions:** When using `:VibingChatWorktree`, the working directory (cwd) is set
in memory only and not saved to frontmatter. This prevents issues when reopening chat files after
worktree deletion. The cwd is only active during the initial VibingChatWorktree session.

### Message Timestamps

Chat messages include timestamps in their headers to help track conversation chronology and
facilitate searching through chat history.

**Timestamp Format:**

```markdown
## 2025-12-28 14:30:00 User

Message content here

## 2025-12-28 14:35:15 Assistant

Response content here
```

**Key Features:**

- **Automatic Timestamping**: Timestamps are automatically added when messages are sent (User) or responses are generated (Assistant)
- **Timezone**: All timestamps use the local system timezone (as returned by Lua's `os.date()`)
- **Backward Compatibility**: Legacy format without timestamps (`## User`, `## Assistant`) is fully supported
- **Searchability**: Timestamps enable easy searching by date/time:
  - Neovim search: `/2025-12-28` to find messages from a specific date
  - File search: `grep "## 2025-12-28" *.vibing` to search across chat files
  - Useful for extracting conversation history for daily reports

**Timestamp Recording:**

- User messages: Timestamp recorded when message is sent (`<CR>` pressed)
- Assistant responses: Timestamp recorded when response begins (in `on_done` callback)

**Implementation:**

The `lua/vibing/utils/timestamp.lua` module provides:

- `create_header(role, timestamp)` - Generate timestamped headers
- `extract_role(line)` - Parse role from both timestamped and legacy headers
- `has_timestamp(line)` - Check if header includes timestamp
- `extract_timestamp(line)` - Extract timestamp from header
- `is_header(line)` - Validate header format

### AskUserQuestion Support

vibing.nvim supports Claude's `AskUserQuestion` tool, allowing Claude to ask clarifying questions during code generation. Instead of guessing or assuming, Claude can present multiple-choice questions for user confirmation.

**How It Works:**

1. **Claude asks a question** - When Claude needs clarification, it sends an `AskUserQuestion` event
2. **Question appears in chat** - The question and options are inserted into the chat buffer as plain text:
   - **Single-select questions**: Numbered list format (`1. 2. 3.`)
   - **Multi-select questions**: Bullet list format (`- - -`)

```markdown
Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Please answer the question and press `<CR>` to send.
```

3. **User edits to select** - Delete unwanted options using Vim's standard editing commands (`dd`, etc.)
4. **Send with `<CR>`** - Press `<CR>` to send the answer back to Claude

**Example Workflow:**

```markdown
## Assistant

Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Which features do you need? (multiple selection allowed)

- Authentication
- Logging
- Caching

Please answer the question and press `<CR>` to send.
```

After editing (removing unwanted options):

```markdown
## Assistant

Which database should we use?

1. PostgreSQL

Which features do you need? (multiple selection allowed)

- Authentication
- Logging

Please answer the question and press `<CR>` to send.
```

**Key Features:**

- **Natural Vim workflow** - Use standard Vim commands (`dd`, `d{motion}`, etc.) to select options
- **Visual selection type indicators** - Numbered lists for single-select, bullet lists for multi-select
- **Single and multiple selection** - Delete unwanted options; remaining options are selected
- **Additional instructions** - Add custom notes below the options before sending
- **Non-invasive** - No special keymaps or UI overlays; works with any buffer editing

**Implementation Details:**

- Agent Wrapper sends `insert_choices` event and denies the tool
- Choices are inserted into chat buffer as plain markdown
  - Single-select (`multiSelect: false`): Numbered list format
  - Multi-select (`multiSelect: true`): Bullet list format
- User edits choices and sends via normal message flow (`<CR>`)
- Claude receives selection as a regular user message
- No special state management or Promise handling required

### Tool Approval UI

vibing.nvim provides an interactive approval UI for tool usage when permission mode is set to `default` or when specific tools are in the `ask` list. Instead of using Agent SDK's console prompts, vibing.nvim presents approval options directly in the chat buffer.

**How It Works:**

1. **Claude requests a tool** - When Claude tries to use a tool that requires approval, the Agent Wrapper sends an `approval_required` event
2. **Approval UI appears in chat** - The tool information and approval options are inserted into the chat buffer as plain text:

```markdown
⚠️ Tool approval required

Tool: Bash
Command: npm install

1. allow_once - Allow this execution only
2. deny_once - Deny this execution only
3. allow_for_session - Allow for this session
4. deny_for_session - Deny for this session

Please select and press <CR> to send.
```

3. **User edits to select** - Delete unwanted options using Vim's standard editing commands (`dd`, etc.)
4. **Send with `<CR>`** - Press `<CR>` to send the approval decision

**Approval Options:**

- **allow_once** - Allow the tool to execute this one time. Next time Claude tries to use the same tool, approval will be required again.
- **deny_once** - Deny the tool execution this one time. Claude will try an alternative approach. Next time the tool may be allowed.
- **allow_for_session** - Add the tool to the session-level allow list. For the rest of this chat session, the tool will be auto-approved.
- **deny_for_session** - Add the tool to the session-level deny list. For the rest of this chat session, the tool will be auto-denied.

**Example Workflow:**

```markdown
## User

Can you run `npm install` to install dependencies?

## Assistant

⚠️ Tool approval required

Tool: Bash
Command: npm install

1. allow_once - Allow this execution only
2. deny_once - Deny this execution only
3. allow_for_session - Allow for this session
4. deny_for_session - Deny for this session

Please select and press <CR> to send.
```

After editing (keeping only the desired option):

```markdown
## User

3. allow_for_session - Allow for this session

## Assistant

User approved Bash for this session. Please try again.

Running npm install...
```

**Key Features:**

- **Natural Vim workflow** - Use standard Vim commands (`dd`, `d{motion}`, etc.) to select approval option
- **Session-level permissions** - `allow_for_session` and `deny_for_session` persist for the entire chat session
- **Detailed context** - Shows tool name and relevant input (command, file path, URL, etc.)
- **Non-invasive** - No special keymaps or UI overlays; works with standard buffer editing
- **AskUserQuestion-like UX** - Consistent with Claude's question-asking interface

**Implementation Details:**

- Agent Wrapper sends `approval_required` event and denies the tool
- Approval UI is inserted into chat buffer as plain markdown with numbered list
- User edits to select option and sends via normal message flow (`<CR>`)
- Buffer parser detects approval response and updates session permissions
- Assistant responds with confirmation message
- Claude retries the tool with updated session permissions

### Permissions Configuration

vibing.nvim provides comprehensive permission control over what tools Claude can use:

#### Permission Modes

```lua
require("vibing").setup({
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
  },
})
```

**Permission Modes:**

- `default` - Ask for user confirmation before each tool use
- `acceptEdits` - Auto-approve Edit/Write operations, ask for others (recommended)
- `bypassPermissions` - Auto-approve all operations (use with caution)

**Basic Permission Logic:**

- Deny list takes precedence over allow list
- If allow list is specified, only those tools are permitted
- If allow list is empty, all tools except denied ones are allowed
- Denied tools will return an error message when Claude attempts to use them

**Available Tools:** Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch

#### Granular Permission Rules

For fine-grained control, use permission rules based on paths, commands, patterns, or domains:

```lua
require("vibing").setup({
  permissions = {
    mode = "default",
    rules = {
      -- Allow reading specific paths
      {
        tools = { "Read" },
        paths = { "src/**", "tests/**" },
        action = "allow",
      },
      -- Deny writing to critical files
      {
        tools = { "Write", "Edit" },
        paths = { ".env", "*.secret", "*.key" },
        action = "deny",
        message = "Cannot modify sensitive files",
      },
      -- Allow specific npm/yarn commands
      {
        tools = { "Bash" },
        commands = { "npm", "yarn" },
        action = "allow",
      },
      -- Deny dangerous bash patterns
      {
        tools = { "Bash" },
        patterns = { "^rm -rf", "^sudo", "^dd if=" },
        action = "deny",
        message = "Dangerous command blocked",
      },
      -- Allow specific domains for web tools
      {
        tools = { "WebFetch", "WebSearch" },
        domains = { "github.com", "*.npmjs.com", "docs.rs" },
        action = "allow",
      },
    },
  },
})
```

**Rule Fields:**

- `tools` - Array of tool names to apply the rule to
- `paths` - Glob patterns for file paths (Read/Write/Edit)
- `commands` - Array of allowed/denied command names (Bash)
- `patterns` - Regex patterns for command matching (Bash)
- `domains` - Domain patterns for web requests (WebFetch/WebSearch)
- `action` - "allow" or "deny"
- `message` - Custom error message (optional, for deny rules)

**Rule Evaluation Order:**

Permission rules are evaluated in the following order to ensure security:

1. **Deny rules are evaluated first** - If any deny rule matches, access is immediately blocked
2. **Allow rules are evaluated second** - If no deny rule matches and an allow rule matches, access is granted
3. **Default deny** - If no rules match, access is denied with "No matching allow rule"

**Security Features:**

- **Path Normalization** - All file paths are normalized to absolute paths and symlinks are resolved to prevent directory traversal attacks
- **Pattern Matching** - Glob patterns support `*` (single directory) and `**` (recursive) wildcards
- **Explicit Allow** - When using rules, you must explicitly allow operations (deny-by-default)

#### Interactive Permission Builder

Use the `/permissions` (or `/perm`) slash command in chat to interactively configure permissions:

```vim
/permissions
```

This launches an interactive UI that guides you through:

1. Selecting a tool (Read, Edit, Write, Bash, etc.)
2. Choosing allow or deny
3. Optionally specifying Bash command patterns
4. Automatically updating chat frontmatter

The Permission Builder provides a user-friendly alternative to manually editing configuration
or frontmatter.

### Key Patterns

**Adapter Pattern:** All AI backends implement the `Adapter` interface with `execute()`, `stream()`,
`cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Permission System:** Three-layer permission control:

1. **Allow/Deny Lists** - Basic tool-level permissions
2. **Permission Modes** - Automation level (default/acceptEdits/bypassPermissions)
3. **Granular Rules** - Path/command/pattern/domain-based fine-grained control

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

## Configuration

Example configuration showing all available settings:

```lua
require("vibing").setup({
  agent = {
    default_mode = "code",    -- "code" | "plan" | "explore"
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
  },
  chat = {
    window = {
      position = "current",  -- "current" | "right" | "left" | "top" | "bottom" | "back" | "float"
      width = 0.4,
      height = 0.4,  -- Used for "top" and "bottom" positions
      border = "rounded",
    },
    auto_context = true,
    save_location_type = "project",  -- "project" | "user" | "custom"
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",  -- Used when "custom"
    context_position = "append",  -- "prepend" | "append"
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",  -- Open diff viewer on file paths
    open_file = "gf",  -- Open file on file paths
  },
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
    rules = {},  -- Optional granular rules
  },
  node = {
    executable = "auto",  -- "auto" (detect from PATH) or explicit path like "/usr/bin/node" or "/usr/local/bin/bun"
    dev_mode = false,  -- false: Use compiled JS, true: Use TypeScript directly with bun
  },
  mcp = {
    enabled = false,  -- MCP integration disabled by default
    rpc_port = 9876,
    auto_setup = false,
    auto_configure_claude_json = false,
  },
  language = nil,  -- Optional: "ja" | "en" | { default = "ja", chat = "ja", inline = "en" }
  ui = {
    wrap = "on",  -- "nvim" | "on" | "off" - Line wrap configuration for all vibing buffers
    -- "nvim": Respect Neovim defaults (don't modify wrap settings)
    -- "on": Enable wrap + linebreak (recommended for chat readability)
    -- "off": Disable line wrapping
    tool_result_display = "compact",  -- "none" | "compact" | "full"
    -- "none": Don't show tool execution results
    -- "compact": Show first 100 characters only (default)
    -- "full": Show complete tool output
    gradient = {
      enabled = true,  -- Enable gradient animation during AI response
      colors = { "#cc3300", "#fffe00" },  -- Start and end colors
      interval = 100,  -- Animation update interval in milliseconds
    },
  },
})
```

### Window Positions

vibing.nvim supports multiple window positioning options for the chat interface:

- **`current`**: Open in the current window (replaces current buffer)
- **`right`**: Open as a vertical split on the right side
  - Width controlled by `config.chat.window.width`
- **`left`**: Open as a vertical split on the left side
  - Width controlled by `config.chat.window.width`
- **`top`**: Open as a horizontal split at the top
  - Height controlled by `config.chat.window.height`
- **`bottom`**: Open as a horizontal split at the bottom
  - Height controlled by `config.chat.window.height`
- **`back`**: Create buffer only, no window (accessible via `:ls` and `:bnext`)
  - Buffer is marked as listed for easy navigation
- **`float`**: Open as a floating window
  - Width controlled by `config.chat.window.width`

**Examples:**

```lua
-- Vertical split on the right (40% of screen width)
require("vibing").setup({
  chat = {
    window = {
      position = "right",
      width = 0.4,
    },
  },
})

-- Horizontal split at bottom (30% of screen height)
require("vibing").setup({
  chat = {
    window = {
      position = "bottom",
      height = 0.3,
    },
  },
})

-- Background buffer (no window, access via buffer list)
require("vibing").setup({
  chat = {
    window = {
      position = "back",
    },
  },
})
```

## User Commands

| Command                                   | Description                                                                                         |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `:VibingChat [position\|file]`            | Create new chat with optional position (current\|right\|left\|top\|bottom\|back) or open saved file |
| `:VibingChatWorktree [position] <branch>` | Create git worktree and open chat in it (position: right\|left\|top\|bottom\|back\|current)         |
| `:VibingToggleChat`                       | Toggle existing chat window (preserve current conversation)                                         |
| `:VibingSlashCommands`                    | Show slash command picker in chat                                                                   |
| `:VibingContext [path]`                   | Add file to context (or from oil.nvim if no path)                                                   |
| `:VibingClearContext`                     | Clear all context                                                                                   |
| `:VibingInline [action\|prompt]`          | Rich UI picker (no args) or direct execution (with args). Tab completion enabled.                   |
| `:VibingCancel`                           | Cancel current request                                                                              |

**Command Semantics:**

- **`:VibingChat`** - Always creates a fresh chat window. Optionally specify position to control window placement.
  - `:VibingChat` - New chat using default position from config
  - `:VibingChat current` - New chat in current window
  - `:VibingChat right` - New chat in right split
  - `:VibingChat left` - New chat in left split
  - `:VibingChat top` - New chat in top split
  - `:VibingChat bottom` - New chat in bottom split
  - `:VibingChat back` - New chat as background buffer only (no window)
  - `:VibingChat path/to/file.vibing` - Open saved chat file
- **`:VibingChatWorktree`** - Create or reuse a git worktree for the specified branch and open a chat session in that environment.
  - `:VibingChatWorktree feature-branch` - Create worktree in `.worktrees/feature-branch` and open chat
  - `:VibingChatWorktree right feature-branch` - Same as above, but open chat in right split
  - Position options: `right`, `left`, `top`, `bottom`, `back` (buffer only, no window - accessible via `:bnext`/`:ls`), `current`
  - If the worktree already exists, it will be reused without recreating the environment
  - Automatically copies configuration files (`.gitignore`, `package.json`, `tsconfig.json`, etc.) to the worktree
  - Creates a symbolic link to `node_modules` from the main worktree (if it exists) to avoid duplicate installations
  - Chat files are saved in main repository at `.vibing/worktrees/<branch-name>/` (persists after worktree deletion)
- **`:VibingToggleChat`** - Use to show/hide your current conversation. Preserves the existing chat state.

### Inline Action Examples

**Rich UI Picker (recommended):**

```vim
:'<,'>VibingInline
" Opens a split-panel UI:
" - Left: Action menu (fix, feat, explain, refactor, test)
"   - Navigate: j/k or arrow keys
"   - Move to input: Tab
" - Right: Additional instruction input (optional)
"   - Move to menu: Shift-Tab
" - Execute: Enter (from either panel)
" - Cancel: Esc or Ctrl-c
```

**Keybindings in Rich UI:**

- `j`/`k` or `↓`/`↑` - Navigate action menu
- `Tab` - Move from menu to input field
- `Shift-Tab` - Move from input field to menu
- `Enter` - Execute selected action
- `Esc` or `Ctrl-c` - Cancel

**Direct Execution (with arguments):**

```vim
:'<,'>VibingInline fix       " Fix code issues
:'<,'>VibingInline feat      " Implement feature
:'<,'>VibingInline explain   " Explain code
:'<,'>VibingInline refactor  " Refactor code
:'<,'>VibingInline test      " Generate tests

" With additional instructions
:'<,'>VibingInline explain 日本語で
:'<,'>VibingInline fix using async/await
:'<,'>VibingInline test using Jest with mocks
:'<,'>VibingInline refactor to use functional style
```

**Natural Language Instructions:**

```vim
:'<,'>VibingInline "Convert this function to TypeScript"
:'<,'>VibingInline "Add error handling with try-catch"
:'<,'>VibingInline "Optimize this loop for performance"
```

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command                   | Description                                                 |
| ------------------------- | ----------------------------------------------------------- |
| `/context <file>`         | Add file to context                                         |
| `/clear`                  | Clear context                                               |
| `/save`                   | Save current chat                                           |
| `/summarize`              | Summarize conversation                                      |
| `/mode <mode>`            | Set execution mode (auto/plan/code/explore)                 |
| `/model <model>`          | Set AI model (opus/sonnet/haiku)                            |
| `/permissions` or `/perm` | Interactive Permission Builder - configure tool permissions |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args     |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args      |
| `/permission [mode]`      | Set permission mode (default/acceptEdits/bypassPermissions) |

## Claude Code on the Web

When developing with Claude Code on the web, there are specific Git push constraints that require special handling.

### Git Push Requirements

**Branch Naming:**

- Branch names MUST start with `claude/`
- Branch names MUST end with a matching session ID
- Example: `claude/feature-name-abc123`
- Pushing to non-compliant branches will fail with HTTP 403

**Retry Logic:**

- Network operations may experience transient failures
- Always use exponential backoff retry (2s, 4s, 8s, 16s)
- Maximum 4 retry attempts recommended

### Using the Git Workflow Skill

A comprehensive skill is available at `.claude/skills/git-remote-workflow/SKILL.md` that provides:

**Branch Management:**

- Branch name validation and conversion
- Pattern compliance checking (`claude/*-<sessionId>`)

**Push Operations:**

- Automatic retry with exponential backoff
- Force push handling with safety checks

**Pull Request Creation:**

- GitHub API integration (no `gh` CLI required)
- Multi-line PR descriptions with proper formatting
- Multiple PR creation in one session
- PR update capabilities

**Complete Workflows:**

- Feature development to PR creation
- Review comment resolution
- Multi-PR workflows

**Environment Detection:**

- Automatic detection of Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)
- Environment-specific logic application

**Quick reference:**

```bash
# Create compliant branch
git checkout -b "claude/my-feature-${CLAUDE_SESSION_ID:-9GOGf}"

# Push with retry
for i in 0 1 2 3; do
  [ $i -gt 0 ] && sleep $((2 ** i))
  git push -u origin "$(git branch --show-current)" && break
done

# Create PR via GitHub API
curl -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/owner/repo/pulls" \
  -d '{"title":"My PR","head":"claude/branch-abc","base":"main","body":"Description"}'
```

See `.claude/skills/git-remote-workflow/SKILL.md` for complete documentation, workflows, and troubleshooting.
