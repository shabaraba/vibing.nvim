# Neovim Integration Testing Guide

This guide explains how to test the Neovim MCP server integration with Claude Agent SDK.

## Prerequisites

1. Neovim installed with `--listen` support
2. npm dependencies installed (`npm install`)
3. Terminal access to run both Neovim and the agent wrapper

## Test Setup

### Step 1: Start Neovim with Socket

Open a terminal and start Neovim with a listening socket:

```bash
# Start Neovim with a socket
nvim --listen /tmp/nvim-test.sock test-file.txt
```

This creates a socket at `/tmp/nvim-test.sock` that the agent can connect to.

### Step 2: Set Environment Variable

In a **separate terminal**, set the `NVIM` environment variable to point to the socket:

```bash
export NVIM=/tmp/nvim-test.sock
```

### Step 3: Run Agent Wrapper

Test the integration with a simple prompt:

```bash
node bin/agent-wrapper.mjs \
  --prompt "Get the current Neovim status using mcp__neovim__get_status" \
  --cwd $(pwd)
```

Expected output should include:
- `Neovim integration enabled (socket: /tmp/nvim-test.sock)` in stderr
- JSON lines showing Claude's response
- Status information from Neovim (mode, buffer, cursor position)

## Available Neovim Tools

The following tools are available when the Neovim MCP server is active:

| Tool Name | Description | Parameters |
|-----------|-------------|------------|
| `mcp__neovim__buf_get_lines` | Get lines from current buffer | `start` (default 0), `end` (default -1) |
| `mcp__neovim__buf_set_lines` | Set lines in current buffer | `start`, `end`, `lines` (array) |
| `mcp__neovim__command` | Execute Ex command | `command` (string, no leading colon) |
| `mcp__neovim__get_status` | Get Neovim status | (no parameters) |

## Example Test Prompts

### Read Buffer Content

```bash
node bin/agent-wrapper.mjs \
  --prompt "Read the current buffer content" \
  --cwd $(pwd)
```

### Write to Buffer

```bash
node bin/agent-wrapper.mjs \
  --prompt "Add a comment '// Hello from Claude' at line 1" \
  --cwd $(pwd)
```

### Execute Command

```bash
node bin/agent-wrapper.mjs \
  --prompt "Save the current buffer using the write command" \
  --cwd $(pwd)
```

## Testing from vibing.nvim

### Auto-Detection via $NVIM

When you run `:VibingChat` from Neovim that was started with `--listen`, the `$NVIM` environment variable is automatically set by Neovim. The agent wrapper will detect this and enable the Neovim tools automatically.

### Example Usage in Chat

1. Start Neovim with listen socket:
   ```bash
   nvim --listen /tmp/nvim.sock
   ```

2. Open vibing.nvim chat:
   ```vim
   :VibingChat
   ```

3. Send a message that uses Neovim tools:
   ```
   Check my current buffer status and tell me what file I'm editing
   ```

Claude will use `mcp__neovim__get_status` to retrieve the information.

## Troubleshooting

### "Neovim socket path is required" Error

The agent wrapper couldn't find the `$NVIM` environment variable. Make sure:
- Neovim is running with `--listen`
- The `$NVIM` environment variable is set correctly
- The socket file exists at the specified path

### "Failed to connect to Neovim" Error

The socket exists but connection failed. Check:
- Neovim is still running
- The socket path is correct
- File permissions allow connection

### Tools Not Available

If Neovim tools aren't being used by Claude:
- Check that permission mode allows the tools
- If using `--allow` with a whitelist, make sure Neovim tools are included
- Look for `Neovim integration enabled` message in stderr

## Integration with Permission System

Neovim tools respect the existing permission system:

```bash
# Allow only Neovim read operations
node bin/agent-wrapper.mjs \
  --prompt "Check my buffer" \
  --allow "Read,mcp__neovim__buf_get_lines,mcp__neovim__get_status" \
  --cwd $(pwd)

# Deny Neovim write operations
node bin/agent-wrapper.mjs \
  --prompt "Edit my buffer" \
  --deny "mcp__neovim__buf_set_lines,mcp__neovim__command" \
  --cwd $(pwd)
```

## Next Steps

Once basic integration works:
1. Test from within vibing.nvim chat sessions
2. Verify session persistence with Neovim tools
3. Test permission configurations
4. Add more advanced Neovim tools (LSP, diagnostics, etc.)
