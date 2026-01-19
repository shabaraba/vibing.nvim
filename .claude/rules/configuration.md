# Configuration

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
  diff = {
    tool = "auto",  -- "git" | "mote" | "auto"
    -- "git": Always use git diff
    -- "mote": Always use mote diff (requires mote: https://github.com/shabaraba/mote)
    -- "auto": Use mote if available and initialized, otherwise fallback to git
    mote = {
      ignore_file = ".vibing/.moteignore",  -- Path to .moteignore file
      storage_dir = ".vibing/mote",  -- Path to mote storage directory
    },
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

## Window Positions

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

## Diff Tool Configuration

vibing.nvim supports multiple diff tools for displaying file changes:

### Tool Options

- **`git`**: Always use `git diff` (default behavior, requires git repository)
- **`mote`**: Always use `mote diff` (requires [mote](https://github.com/shabaraba/mote) to be installed and initialized)
- **`auto`**: Automatically select the best available tool (mote preferred, fallback to git)

### mote Integration

[mote](https://github.com/shabaraba/mote) is a fine-grained snapshot management tool that provides richer diff capabilities than git. It tracks changes at a more granular level than git commits.

**Installation:**

```bash
# Homebrew (macOS / Linux)
brew tap shabaraba/tap
brew install mote

# Or from source
cargo install --path .
```

**Setup:**

```bash
# Initialize mote in your project
mote init

# Create snapshots (automatically or manually)
mote snapshot -m "Before refactoring"
```

**Configuration:**

```lua
require("vibing").setup({
  diff = {
    tool = "auto",  -- Automatically use mote if available
    mote = {
      ignore_file = ".vibing/.moteignore",
      storage_dir = ".vibing/mote",
    },
  },
})
```

**Important:** All mote commands use the specified `--ignore-file` and `--storage-dir` options to keep mote data separate from your main project. This prevents interference with your regular mote workflow.

**Behavior:**

- When you press `gd` on a file path in chat, vibing.nvim will:
  1. Check for patch files (if using Agent SDK patch mode)
  2. If no patch files, use the configured diff tool:
     - `auto`: Use mote if installed and initialized, otherwise git
     - `mote`: Always use mote (shows error if not available)
     - `git`: Always use git diff

**Benefits of mote:**

- Fine-grained snapshots (more granular than git commits)
- Content-addressable storage with efficient deduplication
- Works alongside git without conflicts
- Automatic snapshot creation via hooks (Claude Code, git, jj)
