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
    -- "mote": Always use mote diff (requires mote v0.2.0+: https://github.com/shabaraba/mote)
    -- "auto": Use mote if available and initialized, otherwise fallback to git
    mote = {
      ignore_file = ".vibing/.moteignore",  -- Path to .moteignore file
      project = nil,  -- Project name (nil = auto-detect from git repo name)
      context_prefix = "vibing",  -- Context name prefix (default: "vibing")
    },
  },
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "Skill" },
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

## Mote Integration

vibing.nvim uses mote for displaying file changes and tracking modifications.

[mote](https://github.com/shabaraba/mote) is a fine-grained snapshot management tool that provides richer diff capabilities than git. It tracks changes at a more granular level than git commits.

**Installation:**

```bash
# Homebrew (macOS / Linux)
brew tap shabaraba/tap
brew install mote

# Or from source
cargo install --path .
```

**Binary Installation:**

vibing.nvim automatically downloads and bundles platform-specific mote binaries during installation:

```lua
-- Lazy.nvim
{
  "yourusername/vibing.nvim",
  build = "./build.sh",  -- Automatically downloads mote binaries
}
```

The `build.sh` script downloads mote binaries for all supported platforms:

- `bin/mote-darwin-arm64` (macOS Apple Silicon)
- `bin/mote-darwin-x64` (macOS Intel)
- `bin/mote-linux-arm64` (Linux ARM64)
- `bin/mote-linux-x64` (Linux x64)

**Priority:** vibing.nvim uses its bundled mote binary preferentially, falling back to system `mote` only if the bundled binary is unavailable.

**Setup (mote v0.2.0+ --project/--context API):**

```bash
# Initialize mote context (with project-local storage)
# For project root
mote --project vibing-nvim context new vibing-root --context-dir .vibing/mote/vibing-nvim/vibing-root

# For worktree (e.g., feature-x branch)
mote --project vibing-nvim context new vibing-worktree-feature-x --context-dir .vibing/mote/vibing-nvim/vibing-worktree-feature-x

# Create snapshots (automatically or manually)
mote --project vibing-nvim --context vibing-root snapshot -m "Before refactoring"
```

**Note:** vibing.nvim automatically manages contexts per session with project-local storage:

- Project root: `.vibing/mote/<project>/vibing-root/`
- Worktrees: `.vibing/mote/<project>/vibing-worktree-<branch>/`
- Patch files: `.vibing/mote/<project>/<context>/patches/`

Each context is isolated to prevent cross-worktree diff pollution.

**Configuration:**

```lua
require("vibing").setup({
  mote = {
    ignore_file = ".vibing/.moteignore",
    project = nil,  -- nil = auto-detect from git repo name
    context_prefix = "vibing",  -- Context name prefix
  },
})
```

**Important:** All mote commands use the specified `--project` and `--context` options (mote v0.2.0+ API). This keeps mote data separate from your main project and prevents interference with your regular mote workflow.

**Behavior:**

- When you press `gd` on a file path in chat, vibing.nvim will:
  1. Check for patch files (if using Agent SDK patch mode)
  2. If no patch files, use mote to display the diff

**Benefits of mote:**

- Fine-grained snapshots (more granular than git commits)
- Content-addressable storage with efficient deduplication
- Works alongside git without conflicts
- Automatic snapshot creation via hooks (Claude Code, git, jj)
