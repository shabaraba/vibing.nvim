# MCP Integration Setup Example

This guide shows how to set up the MCP (Model Context Protocol) integration between vibing.nvim and Claude Code.

## Prerequisites

- Neovim with vibing.nvim installed
- Claude Code CLI installed
- Node.js 18+ installed

## Step 1: Build the MCP Server

```bash
cd /path/to/vibing.nvim/mcp-server
npm install
npm run build
```

Verify the build succeeded:

```bash
ls -la dist/index.js
```

## Step 2: Configure Neovim

Add MCP configuration to your Neovim config (e.g., `~/.config/nvim/lua/plugins/vibing.lua`):

```lua
return {
  {
    dir = "/path/to/vibing.nvim",
    config = function()
      require("vibing").setup({
        adapter = "agent_sdk",

        -- Enable MCP integration
        mcp = {
          enabled = true,
          rpc_port = 9876,
        },

        -- Optional: Configure permissions
        permissions = {
          mode = "acceptEdits",
          allow = {
            "Read",
            "Edit",
            "Write",
            "Glob",
            "Grep",
          },
          deny = {
            "Bash",
          },
        },
      })
    end,
  },
}
```

## Step 3: Configure Claude Code

Create or update `~/.claude.json`:

```json
{
  "mcpServers": {
    "vibing-nvim": {
      "command": "node",
      "args": ["/absolute/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": {
        "VIBING_RPC_PORT": "9876"
      }
    }
  }
}
```

**Important:** Use absolute paths, not `~` or relative paths.

## Step 4: Start Neovim with MCP

```bash
nvim
```

You should see a notification:

```
[vibing] MCP RPC server started on port 9876
```

## Step 5: Test from Claude Code

Start Claude Code:

```bash
claude
```

Ask Claude to interact with your Neovim instance:

```
> Can you list the buffers in my Neovim instance?
```

Claude will use the `nvim_list_buffers` MCP tool to retrieve buffer information.

## Example Use Cases

### Read Buffer Content

```
> Show me the content of the current buffer
```

Claude uses `nvim_get_buffer` to read the buffer content.

### Modify Buffer

```
> Add a comment "// TODO: refactor" at the top of the current buffer
```

Claude uses:

1. `nvim_get_buffer` to read current content
2. `nvim_set_buffer` to write modified content

### Execute Commands

```
> Save the current buffer
```

Claude uses `nvim_execute` with command "write".

### Get File Information

```
> What file am I currently editing?
```

Claude uses `nvim_get_info` to get filename, filetype, etc.

## Troubleshooting

### Connection Refused

**Symptom:** MCP server cannot connect to Neovim RPC server

**Solutions:**

1. Check Neovim notification shows "MCP RPC server started"
2. Verify port 9876 is not in use: `lsof -i :9876`
3. Restart Neovim

### Request Timeout

**Symptom:** MCP tools timeout after 5 seconds

**Solutions:**

1. Check Neovim logs: `:messages`
2. Verify `vim.schedule()` is not blocked
3. Check buffer is loaded: `:ls`

### Buffer Not Modified

**Symptom:** `nvim_set_buffer` succeeds but buffer unchanged

**Solutions:**

1. Check buffer is modifiable: `:set modifiable?`
2. Reload buffer: `:edit!`
3. Check Neovim logs for errors

### Wrong Port

**Symptom:** MCP server connects to wrong port

**Solutions:**

1. Verify `~/.claude.json` has correct `VIBING_RPC_PORT`
2. Verify Neovim config has matching `mcp.rpc_port`
3. Restart both Neovim and Claude Code

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│ Terminal 1: Neovim                                        │
│  ┌────────────────────────────────────────────────────┐  │
│  │ vibing.nvim                                         │  │
│  │  ├─ RPC Server (port 9876)                         │  │
│  │  │   └─ vim.loop (libuv async I/O)                 │  │
│  │  │       └─ Listens for JSON-RPC requests          │  │
│  │  │                                                   │  │
│  │  └─ Buffer/Command API                              │  │
│  │      └─ vim.schedule() → Main event loop           │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                           ▲
                           │ TCP (localhost:9876)
                           │ JSON-RPC over newline-delimited JSON
                           │
┌──────────────────────────────────────────────────────────┐
│ Terminal 2: Claude Code                                   │
│  ┌────────────────────────────────────────────────────┐  │
│  │ MCP Server (vibing-nvim)                           │  │
│  │  ├─ TCP Client                                     │  │
│  │  │   └─ Connects to Neovim RPC server             │  │
│  │  │                                                   │  │
│  │  └─ MCP Tools                                       │  │
│  │      ├─ nvim_get_buffer                            │  │
│  │      ├─ nvim_set_buffer                            │  │
│  │      ├─ nvim_execute                               │  │
│  │      └─ ...                                         │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Security Considerations

- RPC server only listens on localhost (127.0.0.1)
- No authentication required (local-only access)
- MCP tools have full Neovim API access
- Use vibing.nvim permissions to restrict tool usage

## Advanced Configuration

### Custom Port

```lua
-- Neovim config
require("vibing").setup({
  mcp = {
    enabled = true,
    rpc_port = 8888,  -- Custom port
  },
})
```

```json
// ~/.claude.json
{
  "mcpServers": {
    "vibing-nvim": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": {
        "VIBING_RPC_PORT": "8888"
      }
    }
  }
}
```

### Multiple Neovim Instances

Run each Neovim instance on a different port:

```lua
-- Instance 1 (port 9876)
require("vibing").setup({ mcp = { enabled = true, rpc_port = 9876 } })

-- Instance 2 (port 9877)
require("vibing").setup({ mcp = { enabled = true, rpc_port = 9877 } })
```

Configure separate MCP servers in `~/.claude.json`:

```json
{
  "mcpServers": {
    "vibing-nvim-1": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": { "VIBING_RPC_PORT": "9876" }
    },
    "vibing-nvim-2": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": { "VIBING_RPC_PORT": "9877" }
    }
  }
}
```

## Performance Tips

- Use `nvim_set_buffer` for bulk modifications (faster than multiple `nvim_execute` calls)
- Keep RPC payloads small (avoid transferring huge buffers)
- Use `nvim_list_buffers` to check buffer state before operations

## References

- [MCP Server README](../mcp-server/README.md)
- [vibing.nvim Configuration](../README.md#configuration)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
