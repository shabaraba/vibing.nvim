# vibing.nvim MCP Server

Model Context Protocol (MCP) server for Neovim integration via vibing.nvim.

## Architecture

This MCP server enables Claude Code to interact with a running Neovim instance through a non-blocking RPC architecture:

```
┌─────────────────────────────────────────────────────────┐
│ Neovim Process                                           │
│  ├─ RPC Server (lua/vibing/rpc_server.lua)              │
│  │   └─ vim.loop async TCP server (port 9876)           │
│  │       - Non-blocking I/O via libuv                    │
│  │       - vim.schedule() for safe API calls             │
│  │                                                        │
│  └─ Claude Code (subprocess)                             │
│       └─ MCP Server (this package)                       │
│            └─ TCP client → Neovim RPC server             │
│                 └─ JSON-RPC protocol                     │
└─────────────────────────────────────────────────────────┘
```

**Key Benefits:**

- **No Deadlocks**: Neovim's RPC server uses async I/O (libuv), never blocks
- **Safe API Access**: `vim.schedule()` ensures API calls run on main event loop
- **Bidirectional**: MCP server can both read and write Neovim buffers

## Installation

### 1. Build the MCP Server

**Option 1: Using build script (simplest)**

From plugin root:

```bash
./build.sh
```

**Option 2: Manual build**

```bash
cd mcp-server
npm install
npm run build
```

**Option 3: From Neovim**

```vim
:VibingBuildMcp
```

The build script automatically checks for Node.js 18+, installs dependencies, and compiles TypeScript.

### 2. Configure Claude Code

Add to `~/.claude.json`:

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

### 3. Enable MCP in vibing.nvim

```lua
require("vibing").setup({
  mcp = {
    enabled = true,
    rpc_port = 9876,
  },
})
```

## Available Tools

The MCP server exposes the following tools to Claude:

### Buffer Operations

- **nvim_get_buffer** - Get current buffer content
  - `bufnr` (optional): Buffer number (0 for current)

- **nvim_set_buffer** - Replace buffer content
  - `lines` (required): New content (newline-separated string)
  - `bufnr` (optional): Buffer number (0 for current)

- **nvim_list_buffers** - List all loaded buffers
  - Returns: Array of buffer info (bufnr, name, modified, filetype)

- **nvim_load_buffer** - Load file into buffer without displaying it
  - `filepath` (required): Absolute or relative path to file
  - Returns: `{ bufnr, already_loaded }`
  - Use case: Background loading for LSP operations
  - Simplifies workflow: replaces `nvim_execute("edit")` + `nvim_execute("bp")`

### File Information

- **nvim_get_info** - Get current file information
  - Returns: `{ bufnr, filename, filetype, modified }`

### Cursor Operations

- **nvim_get_cursor** - Get cursor position
  - Returns: `{ line, col }`

- **nvim_set_cursor** - Set cursor position
  - `line` (required): Line number (1-indexed)
  - `col` (optional): Column number (0-indexed)

- **nvim_get_visual_selection** - Get visual selection
  - Returns: `{ lines, start, end }`

### Window Operations

- **nvim_list_windows** - List all windows with their properties
  - Returns: Array of window info (winnr, bufnr, buffer_name, filetype, width, height, position, is_current, is_floating)

- **nvim_get_window_info** - Get detailed information for a specific window
  - `winnr` (optional): Window number (0 for current)
  - Returns: Detailed window info including cursor position

- **nvim_get_window_view** - Get window viewport information
  - `winnr` (optional): Window number (0 for current)
  - Returns: `{ winnr, bufnr, topline, botline, width, height, cursor, leftcol }`

- **nvim_list_tabpages** - List all tab pages with their windows
  - Returns: Array of tab info (tabnr, window_count, windows, is_current)

- **nvim_set_window_size** - Resize window
  - `winnr` (optional): Window number (0 for current)
  - `width` (optional): New window width
  - `height` (optional): New window height

- **nvim_focus_window** - Move focus to a specific window
  - `winnr` (required): Window number to focus

- **nvim_win_set_buf** - Set an existing buffer in a specific window
  - `winnr` (required): Window number
  - `bufnr` (required): Buffer number to display

- **nvim_win_open_file** - Open a file in a specific window without switching focus
  - `winnr` (required): Window number
  - `filepath` (required): Path to file to open
  - Returns: `{ success, bufnr }`

### Command Execution

- **nvim_execute** - Execute Neovim command
  - `command` (required): Neovim command string (e.g., "write", "edit foo.txt")

### LSP Operations

- **nvim_lsp_definition** - Get definition location(s) of symbol
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ locations: [{ uri, range }] }`

- **nvim_lsp_references** - Get all references to symbol
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ references: [{ uri, range }] }`

- **nvim_lsp_hover** - Get hover information (type, documentation)
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ contents: "..." }`

- **nvim_diagnostics** - Get diagnostics (errors, warnings) for buffer
  - `bufnr` (optional): Buffer number (0 for current)
  - Returns: `{ diagnostics: [{ lnum, col, severity, message, source }] }`

- **nvim_lsp_document_symbols** - Get all symbols in the document
  - `bufnr` (optional): Buffer number (0 for current)
  - Returns: `{ symbols: [...] }` (LSP DocumentSymbol array)

- **nvim_lsp_type_definition** - Get type definition location(s)
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ locations: [{ uri, range }] }`

- **nvim_lsp_call_hierarchy_incoming** - Get incoming calls (callers)
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ calls: [{ from, fromRanges }] }`

- **nvim_lsp_call_hierarchy_outgoing** - Get outgoing calls (callees)
  - `bufnr` (optional): Buffer number (0 for current)
  - `line` (required): Line number (1-indexed)
  - `col` (required): Column number (0-indexed)
  - Returns: `{ calls: [{ to, fromRanges }] }`

## Usage Examples

### From Claude Code

```javascript
// Get current buffer content
const content = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {});

// Modify buffer
await use_mcp_tool('vibing-nvim', 'nvim_set_buffer', {
  lines: 'line 1\nline 2\nline 3',
});

// Execute Neovim command
await use_mcp_tool('vibing-nvim', 'nvim_execute', {
  command: 'write',
});

// List all buffers
const buffers = await use_mcp_tool('vibing-nvim', 'nvim_list_buffers', {});

// List all windows
const windows = await use_mcp_tool('vibing-nvim', 'nvim_list_windows', {});

// Get current window viewport
const viewport = await use_mcp_tool('vibing-nvim', 'nvim_get_window_view', {});

// Resize current window
await use_mcp_tool('vibing-nvim', 'nvim_set_window_size', {
  winnr: 0,
  width: 100,
  height: 40,
});

// Focus window 1000
await use_mcp_tool('vibing-nvim', 'nvim_focus_window', { winnr: 1000 });

// Open file in specific window without switching focus
await use_mcp_tool('vibing-nvim', 'nvim_win_open_file', {
  winnr: 1000,
  filepath: '/path/to/file.txt',
});

// Set buffer in specific window
await use_mcp_tool('vibing-nvim', 'nvim_win_set_buf', {
  winnr: 1000,
  bufnr: 5,
});

// Load file into buffer without displaying it (for LSP operations)
const { bufnr } = await use_mcp_tool('vibing-nvim', 'nvim_load_buffer', {
  filepath: 'src/logger.ts',
});
// Now use bufnr for LSP operations without disrupting user's view

// Get definition of symbol at line 10, column 5
const definition = await use_mcp_tool('vibing-nvim', 'nvim_lsp_definition', {
  line: 10,
  col: 5,
});

// Get all references to symbol
const references = await use_mcp_tool('vibing-nvim', 'nvim_lsp_references', {
  line: 10,
  col: 5,
});

// Get hover information (type, documentation)
const hover = await use_mcp_tool('vibing-nvim', 'nvim_lsp_hover', {
  line: 10,
  col: 5,
});

// Get diagnostics for current buffer
const diagnostics = await use_mcp_tool('vibing-nvim', 'nvim_diagnostics', {});

// Get all symbols in the document
const symbols = await use_mcp_tool('vibing-nvim', 'nvim_lsp_document_symbols', {});

// Get type definition
const typeDef = await use_mcp_tool('vibing-nvim', 'nvim_lsp_type_definition', {
  line: 10,
  col: 5,
});

// Get incoming calls (who calls this function?)
const incomingCalls = await use_mcp_tool('vibing-nvim', 'nvim_lsp_call_hierarchy_incoming', {
  line: 10,
  col: 5,
});

// Get outgoing calls (what does this function call?)
const outgoingCalls = await use_mcp_tool('vibing-nvim', 'nvim_lsp_call_hierarchy_outgoing', {
  line: 10,
  col: 5,
});
```

## Development

### Watch Mode

```bash
npm run dev
```

### Testing

1. Start Neovim with vibing.nvim and MCP enabled
2. Start Claude Code with the MCP server configured
3. Use Claude to interact with your Neovim instance

## RPC Protocol

The server uses a simple JSON-RPC protocol over TCP:

**Request:**

```json
{ "id": 1, "method": "buf_get_lines", "params": { "bufnr": 0 } }
```

**Response:**

```json
{ "id": 1, "result": ["line 1", "line 2", "line 3"] }
```

**Error:**

```json
{ "id": 1, "error": "Buffer not found" }
```

## Troubleshooting

### Connection Refused

- Ensure Neovim is running with MCP enabled
- Check that RPC server port (9876) is not in use
- Verify `VIBING_RPC_PORT` environment variable matches config

### Request Timeout

- Default timeout is 5 seconds
- Check Neovim logs for errors in RPC server
- Ensure `vim.schedule()` is not blocked

### Buffer Modifications Not Appearing

- Verify buffer is modifiable (`:set modifiable?`)
- Check if buffer is loaded (`:ls`)
- Reload buffer if needed (`:edit!`)

## License

Same as vibing.nvim (MIT)
