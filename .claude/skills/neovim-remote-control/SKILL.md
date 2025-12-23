---
name: neovim-remote-control
description: Control remote Neovim instances via Unix socket (nvim --listen). Use when user wants to manipulate Neovim buffers, send commands, or get state from a separate Neovim instance during testing or development.
allowed-tools: Bash, Read
---

# Neovim Remote Control

This skill provides Unix socket-based communication with remote Neovim instances for testing, development, and automation.

## When to Use

- User asks to control or interact with a remote Neovim instance
- E2E testing scenarios where Claude needs to manipulate Neovim
- User gives natural language instructions like "open this file in Neovim buffer"
- Socket path is available (`$NVIM` environment variable or configured)

## Available API

The remote control module is in `lua/vibing/remote.lua` and provides these functions:

### Core Functions

**`setup(socket_path?)`**
Initialize remote control with optional socket path (auto-detects from `$NVIM` if not provided).

**`is_available()`**
Check if remote control is available (returns boolean).

**`send(keys)`**
Send key sequences to remote Neovim.
Examples: `"iHello<Esc>"`, `":w<CR>"`, `"gg=G"`

**`expr(expr)`**
Evaluate Vim expression and return result.
Examples: `"line('.')"`, `"getline(1, '$')"`, `"bufname('%')"`

**`execute(command)`**
Execute Ex command (without colon prefix).
Examples: `"write"`, `"edit foo.lua"`, `"buffers"`

**`get_buffer()`**
Get all lines from current buffer as array.

**`get_status()`**
Get current Neovim state: `{mode, bufname, line, col}`

## Direct nvim --server Usage

For most operations, use `nvim --server` commands directly instead of loading Lua:

### Send Commands

```bash
# Edit a file
nvim --server /tmp/nvim.sock --remote-send ":edit test.lua<CR>"

# Save current buffer
nvim --server /tmp/nvim.sock --remote-send ":write<CR>"

# Insert text
nvim --server /tmp/nvim.sock --remote-send "iHello World<Esc>"

# Execute normal mode commands
nvim --server /tmp/nvim.sock --remote-send "gg=G"
```

### Evaluate Expressions

```bash
# Get current line number
nvim --server /tmp/nvim.sock --remote-expr "line('.')"

# Get buffer content
nvim --server /tmp/nvim.sock --remote-expr "getline(1, '$')"

# Get buffer name
nvim --server /tmp/nvim.sock --remote-expr "bufname('%')"

# Get current mode
nvim --server /tmp/nvim.sock --remote-expr "mode()"
```

### Socket Path Detection

```bash
# Check if NVIM environment variable is set
if [ -n "$NVIM" ]; then
  SOCKET="$NVIM"
elif [ -S "/tmp/nvim.sock" ]; then
  SOCKET="/tmp/nvim.sock"
else
  echo "No Neovim socket available"
  exit 1
fi

# Use the socket
nvim --server "$SOCKET" --remote-send ":edit config.lua<CR>"
```

## Common Workflows

### Workflow 1: Open File in Remote Neovim

When user says "open config.lua in the buffer":

```bash
# Detect socket
SOCKET="${NVIM:-/tmp/nvim.sock}"

# Check if socket exists
if [ ! -S "$SOCKET" ]; then
  echo "❌ Neovim socket not available. Start nvim with --listen"
  exit 1
fi

# Open file
nvim --server "$SOCKET" --remote-send ":edit config.lua<CR>"
echo "✅ Opened config.lua in remote Neovim"
```

### Workflow 2: Get Buffer Information

```bash
SOCKET="${NVIM:-/tmp/nvim.sock}"

# Get current buffer name
BUFNAME=$(nvim --server "$SOCKET" --remote-expr "bufname('%')")

# Get current line
LINE=$(nvim --server "$SOCKET" --remote-expr "line('.')")

# Get mode
MODE=$(nvim --server "$SOCKET" --remote-expr "mode()")

echo "Buffer: $BUFNAME, Line: $LINE, Mode: $MODE"
```

### Workflow 3: E2E Testing

```bash
# Start Neovim with socket
nvim --listen /tmp/nvim.sock &
NVIM_PID=$!
sleep 1  # Wait for Neovim to start

# Run test commands
nvim --server /tmp/nvim.sock --remote-send ":edit test.lua<CR>"
nvim --server /tmp/nvim.sock --remote-send "ilocal x = 1<Esc>:w<CR>"

# Verify content
CONTENT=$(nvim --server /tmp/nvim.sock --remote-expr "getline(1, '$')")
if echo "$CONTENT" | grep -q "local x = 1"; then
  echo "✅ Test passed"
else
  echo "❌ Test failed"
fi

# Cleanup
kill $NVIM_PID
```

### Workflow 4: Modify Buffer Content

```bash
SOCKET="${NVIM:-/tmp/nvim.sock}"

# Append line to buffer
nvim --server "$SOCKET" --remote-send "Go-- New comment<Esc>:w<CR>"

# Replace word under cursor
nvim --server "$SOCKET" --remote-send "ciwNewWord<Esc>"

# Format entire buffer
nvim --server "$SOCKET" --remote-send "gg=G"
```

## Setup Requirements

### Starting Neovim with Socket

```bash
# Method 1: Explicit socket path
nvim --listen /tmp/nvim.sock

# Method 2: Using environment variable
export NVIM=/tmp/nvim.sock
nvim

# Method 3: Random socket (Neovim picks path)
nvim --listen
```

### vibing.nvim Configuration

The remote module is automatically initialized when auto-detect is enabled:

```lua
require("vibing").setup({
  remote = {
    socket_path = nil,  -- Auto-detect from NVIM env variable
    auto_detect = true,
  },
})
```

## Troubleshooting

### Issue 1: Socket Not Found

**Symptom**: `"Remote control not available"`

**Debug**:

```bash
# Check if Neovim is running with --listen
ps aux | grep "nvim.*listen"

# Check NVIM environment variable
echo "$NVIM"

# List sockets in /tmp
ls -la /tmp/*.sock 2>/dev/null
```

**Solution**: Start Neovim with `--listen`:

```bash
nvim --listen /tmp/nvim.sock
```

### Issue 2: Permission Denied

**Symptom**: Cannot access socket file

**Debug**:

```bash
# Check socket permissions
ls -l "$NVIM"

# Check ownership
stat "$NVIM"
```

**Solution**: Ensure socket is owned by current user.

### Issue 3: Commands Not Working

**Symptom**: Commands execute but don't seem to work

**Debug**:

```bash
# Check current mode
MODE=$(nvim --server "$NVIM" --remote-expr "mode()")
echo "Current mode: $MODE"
```

**Solution**: Ensure correct mode for command. Use `<Esc>` to return to normal mode:

```bash
# Return to normal mode first
nvim --server "$NVIM" --remote-send "<Esc>:edit test.lua<CR>"
```

### Issue 4: Expression Returns Nothing

**Symptom**: `--remote-expr` returns empty string

**Debug**:

```bash
# Try simple expression
nvim --server "$NVIM" --remote-expr "1+1"

# Check if Neovim is responsive
nvim --server "$NVIM" --remote-expr "mode()"
```

**Solution**: Verify Neovim is running and socket is correct.

## Quick Reference

### Essential Commands

```bash
# Check availability
[ -S "${NVIM:-/tmp/nvim.sock}" ] && echo "Available" || echo "Not available"

# Open file
nvim --server "$NVIM" --remote-send ":edit file.lua<CR>"

# Save buffer
nvim --server "$NVIM" --remote-send ":write<CR>"

# Get status
nvim --server "$NVIM" --remote-expr "printf('%s - %s:%d', mode(), bufname('%'), line('.'))"

# Insert text
nvim --server "$NVIM" --remote-send "iHello<Esc>"
```

### Special Key Sequences

Common special keys for `--remote-send`:

- `<CR>` - Enter/Return
- `<Esc>` - Escape
- `<C-c>` - Ctrl+C
- `<C-w>` - Ctrl+W (window commands)
- `<Space>` - Space
- `<Tab>` - Tab
- `<BS>` - Backspace

### Vim Expression Examples

Useful expressions for `--remote-expr`:

```bash
# Line/column
"line('.')"           # Current line number
"col('.')"            # Current column number
"line('$')"           # Last line number

# Buffer info
"bufname('%')"        # Current buffer name
"getline(1, '$')"     # All buffer lines
"getline('.')"        # Current line content

# Mode/state
"mode()"              # Current mode (n/i/v/etc)
"&filetype"           # Current filetype
"getcwd()"            # Current working directory
```
