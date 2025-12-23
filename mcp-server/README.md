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

### Command Execution

- **nvim_execute** - Execute Neovim command
  - `command` (required): Neovim command string (e.g., "write", "edit foo.txt")

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
