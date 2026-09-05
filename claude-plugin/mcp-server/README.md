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

### Option 0: vibing.nvim's own bundled plugin (the default — nothing to install)

This MCP server ships inside vibing.nvim's [Claude Code plugin](https://code.claude.com/docs/en/plugins),
alongside Neovim-aware skills and an `nvim-navigator` subagent. vibing.nvim hands the plugin
directory to the `claude` CLI per session with `--plugin-dir`, so it is never installed into
Claude Code's global state and never has to be kept in sync with anything: the server that runs
is always the one in the checkout that spawned it — a git worktree included.

`../../build.sh` builds it; there is no registration step. The tools arrive as
`mcp__plugin_vibing-nvim_vibing-nvim__*`, the same names a marketplace install produced, because
the prefix comes from `../.claude-plugin/plugin.json`'s `name` rather than from how the plugin
was loaded.

The consequence worth knowing: a `claude` session started outside Neovim does not get these
tools. Reaching a running Neovim was always the point of them, so there is no opt-in for it.

The manual options below remain useful for development, for a non-default RPC port/timeout, or
for copilot (`copilot mcp add`, which `build.sh` still does — that CLI has no plugin system).
Codex is handed the server per session too, as `-c mcp_servers.vibing-nvim.*` overrides, so a
global `codex mcp add` entry is only needed for codex sessions started outside Neovim
(`handbook/architecture/plugin-and-commands.md` → "Codex").

**Upgrading:** if an older vibing.nvim installed this as a user-scope plugin, `build.sh` removes
it. By hand:

```text
/plugin uninstall vibing-nvim@vibing
/plugin marketplace remove vibing
```

**Auto-build mechanism:** `mcp-server/bin/run.mjs` hashes `package.json`, `package-lock.json`,
`tsconfig.json`, and everything under `src/` into a fingerprint stored at
`dist/.build-fingerprint`, and rebuilds whenever that fingerprint changes (or `dist/`/
`node_modules` are missing) rather than only on first launch. To force a rebuild manually, delete
`dist/.build-fingerprint` (or the whole `dist/` directory) and relaunch, or just run
`npm ci && npm run build` directly in this directory.

That rebuild happens inside the 30 seconds Claude Code allows a plugin's MCP server to start, so
the install runs with `--prefer-offline --no-audit --no-fund`. npm's registry round-trips are not
a fixed cost — the same `npm ci` on the same warm cache was measured at 31.1s once and ~1.5s hours
later — and blowing the deadline leaves the tools silently absent from the session, so the flags
are there to keep the step bounded by local work rather than by registry latency. A **cold** cache
still takes minutes and no flag helps; run `./build.sh` once after a dependency bump, which does
the same install under no deadline and stamps the fingerprint so the next launch skips the build.
See `handbook/architecture/plugin-and-commands.md` → "The MCP server's own startup budget".

### 1. Build the MCP Server

**Option 1: Using build script (simplest)**

From the repository root (one level above this plugin root, where `build.sh` lives):

```bash
./build.sh
```

**Option 2: Manual build**

```bash
cd claude-plugin/mcp-server
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
      "args": ["/path/to/vibing.nvim/claude-plugin/mcp-server/dist/index.js"],
      "env": {
        "VIBING_RPC_PORT": "9876",
        "VIBING_RPC_TIMEOUT": "30000"
      }
    }
  }
}
```

**Environment Variables:**

- `VIBING_RPC_PORT`: RPC server port (default: 9876)
- `VIBING_RPC_TIMEOUT`: Request timeout in milliseconds (default: 30000 = 30 seconds)

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
  - `file_path` (optional): A vibing.nvim chat file to read instead, opened in the background if
    it is not already open. Mutually exclusive with `bufnr`; chat files only (use
    **nvim_load_buffer** for an ordinary file)

- **nvim_set_buffer** - Replace buffer content
  - `lines` (required): New content (newline-separated string)
  - `bufnr` (optional): Buffer number (0 for current)

- **nvim_list_buffers** - List all loaded buffers
  - Returns: Array of buffer info (bufnr, name, modified, filetype)

- **nvim_load_buffer** - Load a file into a buffer without displaying it
  - `filepath` (required): Absolute or relative path to file
  - Returns: `{ bufnr, already_loaded }`
  - Use case: give the LSP tools a buffer to work on without changing what the user is looking at

### File Information

- **nvim_get_info** - Get metadata for the current file only, no content (use **nvim_get_buffer** for content)
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

### Highlighting

- **nvim_highlight_range** - Temporarily highlight a line range so the user can see which code you
  mean. Pair with `nvim_win_open_file` and `nvim_set_cursor` to open and jump there first
  - `bufnr` (required): Buffer number (0 for current)
  - `start_line` (required): First line to highlight (1-indexed)
  - `end_line` (optional): Last line, inclusive (defaults to `start_line`)
  - `duration_ms` (optional): Auto-clear delay, default 3000. `0` keeps it until the next
    highlight or `nvim_clear_highlight`
  - Uses the `VibingHighlight` group, `default link`ed to `Visual` and overridable with
    `hi VibingHighlight ...`

- **nvim_clear_highlight** - Remove the highlight before it times out
  - `bufnr` (required): Buffer number (0 for current)

### Chat

- **nvim_chat_create** - Create a worker chat buffer and return its `bufnr` and `file_path`
  - `position` (optional): Window position, defaults to `back` (buffer only, no window)
  - `working_dir` (optional): Git-root-relative directory the chat runs in; must already exist
  - `from_bufnr` (optional): The calling chat's buffer number, recorded as this chat's
    orchestrator in both files' frontmatter

- **nvim_chat_send_message** - Send a message to a chat buffer and start an AI request
  - `file_path` / `bufnr` (exactly one): The target chat. `file_path` is the form that survives a
    Neovim restart — a buffer number only means anything in the session that issued it, while the
    path is what the chats record in their own frontmatter — and a chat that is not open is
    opened in the background. Passing both is an error rather than a silent preference
  - `message` (required): Message text
  - `sender` (optional): Sender label, defaults to "User"
  - `from_bufnr` (optional): The calling chat's buffer number. Records the orchestration
    relationship in both chat files' frontmatter (`orchestrated` / `orchestrated_by`), so it
    outlives the buffer numbers and file names it was built from

- **nvim_chat_answer_approval** - Answer another chat's pending tool-approval prompt, the stop
  that leaves it at status `waiting_approval` unable to continue or report. **Refused unless the
  user set `agent.orchestration.delegated_approval`** — by default only the user can clear that
  prompt, and the error says so
  - `file_path` / `bufnr` (exactly one): The blocked chat, addressed as above
  - `action` (required): `allow_once` / `deny_once` / `allow_for_session` / `deny_for_session` —
    the same four options the prompt offers the user. The `_for_session` pair is written into that
    chat's frontmatter and applies to every later call in it
  - `from_bufnr` (**required**, unlike on the two tools above): The answering chat's buffer
    number. The answer is recorded in the blocked chat as coming from it, so a call that cannot
    say whose decision it was is refused

- **nvim_ask_user_question** - Render a multiple-choice question in the chat buffer. This cancels
  the in-flight turn; the user's answer arrives as the next turn's message
  - `chat_bufnr` (required): Chat buffer number
  - `questions` (required): Array of `{ question, options, multiSelect? }`

### Instances

- **nvim_list_instances** - List running Neovim instances with a vibing.nvim RPC server
  - Returns: `{ instances: [{ pid, port, cwd, started_at }] }`

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

### Quickfix

- **nvim_set_qflist** - Push a route of file:line stops as a NEW quickfix list
  - `items` (required): `[{ filename, lnum, col?, text? }]` in visiting order. `lnum`/`col` are
    1-based here, matching native quickfix — not the 0-based `col` the cursor and LSP tools use
  - `title` (optional): quickfix list title (default `"vibing.nvim"`)
  - `open` (optional): also open the quickfix window, without moving focus
  - Returns: `{ success, count, title, qf_winnr? }`
  - The previous quickfix list is never overwritten — it stays reachable with `:colder`. Any
    invalid or nonexistent stop rejects the whole call rather than being dropped

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

// Leave a code tour route in quickfix for the user to replay with :cnext
await use_mcp_tool('vibing-nvim', 'nvim_set_qflist', {
  title: 'Code tour: request handling',
  open: true,
  items: [
    { filename: 'src/server.ts', lnum: 42, text: 'request enters here' },
    { filename: 'src/router.ts', lnum: 17, text: 'dispatched by path' },
  ],
});

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

- Default timeout is 30 seconds (configurable via `VIBING_RPC_TIMEOUT` env var)
- For heavy LSP operations (e.g., call hierarchy in large projects), consider increasing timeout:
  ```json
  "env": {
    "VIBING_RPC_PORT": "9876",
    "VIBING_RPC_TIMEOUT": "60000"
  }
  ```
- Check Neovim logs for errors in RPC server
- Ensure `vim.schedule()` is not blocked

### Buffer Modifications Not Appearing

- Verify buffer is modifiable (`:set modifiable?`)
- Check if buffer is loaded (`:ls`)
- Reload buffer if needed (`:edit!`)

## License

Same as vibing.nvim (MIT)
