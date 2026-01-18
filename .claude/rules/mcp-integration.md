# MCP Integration (Model Context Protocol)

vibing.nvim provides MCP server integration that enables Claude Code to interact with a running
Neovim instance without deadlocks. The architecture uses an async RPC server to avoid blocking
issues.

## User MCP Servers, Slash Commands, Skills, and Subagents

**IMPORTANT:** vibing.nvim's Agent SDK wrapper (`bin/agent-wrapper.mjs`) automatically loads user and project
settings via `settingSources: ['user', 'project']`. This means:

- User's custom MCP servers from `~/.claude.json` are available
- Project slash commands from `.claude/commands/` work out of the box
- Project and user skills from `.claude/skills/` can be invoked
- User's global settings and subagents are inherited

You can use ALL your existing Claude Code configuration and tools within vibing.nvim sessions
without any additional configuration. The vibing-nvim MCP server is automatically registered as
a user-level MCP server during the build process (`build.sh`).

## Architecture

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

## Available MCP Tools

When using these tools from Claude Code, prefix them with `mcp__vibing-nvim__`:

### Buffer Operations

- `nvim_get_buffer` - Get current buffer content
- `nvim_set_buffer` - Replace buffer content
- `nvim_list_buffers` - List all loaded buffers
- `nvim_get_info` - Get current file information
- `nvim_load_buffer` - Load file in background (no window switching)

### Cursor & Selection

- `nvim_get_cursor` - Get cursor position
- `nvim_set_cursor` - Set cursor position
- `nvim_get_visual_selection` - Get visual selection

### Window/Pane Operations

- `nvim_list_windows` - List all windows with properties (buffer, size, position, focus)
- `nvim_get_window_info` - Get detailed window information
- `nvim_get_window_view` - Get viewport info (visible lines, scroll position)
- `nvim_list_tabpages` - List tab pages with their windows
- `nvim_set_window_size` - Resize window width/height
- `nvim_focus_window` - Move focus to a specific window
- `nvim_win_set_buf` - Set an existing buffer in a specific window
- `nvim_win_open_file` - Open a file in a specific window without switching focus

**IMPORTANT - Window Identification:**

- `nvim_get_window_info({ winnr: 0 })` returns info for the **currently active window** (where focus is), NOT the window where the cursor is visually located
- `nvim_list_windows()` returns all windows and indicates which one is active via `is_current: true`
- When working with specific windows (e.g., resizing chat window), always use `nvim_list_windows()` first to find the correct window by matching buffer name or other properties, then use the `winnr` from the result
- In vibing.nvim chat context, the chat window may not be the active window when the request is sent, so always identify the target window explicitly

### Commands

- `nvim_execute` - Execute Neovim commands

### LSP Operations

- `nvim_lsp_definition` - Get definition location(s) of symbol
- `nvim_lsp_references` - Get all references to symbol
- `nvim_lsp_hover` - Get hover information (type, documentation)
- `nvim_diagnostics` - Get diagnostics (errors, warnings)
- `nvim_lsp_document_symbols` - Get all symbols in document
- `nvim_lsp_type_definition` - Get type definition location(s)
- `nvim_lsp_call_hierarchy_incoming` - Get incoming calls (callers)
- `nvim_lsp_call_hierarchy_outgoing` - Get outgoing calls (callees)

## Background LSP Analysis Workflow

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

**Key Points:**

- Files must be loaded into buffers for LSP analysis (use `:edit` or similar)
- Once loaded, buffers remain in memory even when not displayed
- Specify `bufnr` parameter to analyze non-active buffers
- Use `:bprevious` or `:buffer <bufnr>` to return to your original work
- LSP server continues analyzing all loaded buffers in background

## Example Usage

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

// Execute command
await use_mcp_tool('vibing-nvim', 'nvim_execute', { command: 'write' });
```

## Setup

**Quick Setup (Lazy.nvim):**

```lua
return {
  {
    "yourusername/vibing.nvim",
    -- Auto-build MCP server on install/update
    -- This automatically registers vibing-nvim MCP in ~/.claude.json
    build = "./build.sh",
    config = function()
      require("vibing").setup({
        mcp = {
          enabled = true,
          rpc_port = 9876,
          auto_setup = true,
        },
      })
    end,
  },
}
```

**NOTE:** The `build` script now automatically registers the vibing-nvim MCP server in
`~/.claude.json`, so manual configuration is typically not needed.

See `mcp-server/README.md` and `docs/lazy-setup-example.lua` for detailed setup instructions.
