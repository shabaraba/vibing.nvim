<div align="center">

<img src=".github/assets/logo.png" alt="vibing.nvim logo" width="200"/>

# vibing.nvim

**Intelligent AI-Powered Code Assistant for Neovim**

[![CI](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/shabaraba/vibing.nvim)](https://github.com/shabaraba/vibing.nvim/releases)

A powerful Neovim plugin that seamlessly integrates **Claude AI** through the Agent SDK, bringing
intelligent chat conversations and context-aware inline code actions directly into your editor.

[Features](#-features) • [Installation](#-installation) • [Usage](#-usage) •
[Configuration](#️-configuration-examples) • [Contributing](#-contributing)

</div>

---

## Table of Contents

- [Features](#-features)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration Examples](#️-configuration-examples)
- [Configuration Reference](#-configuration-reference)
- [Chat File Format](#-chat-file-format)
- [Architecture](#️-architecture)
- [Contributing](#-contributing)
- [License](#-license)
- [Links](#-links)

## ✨ Features

- **💬 Interactive Chat Interface** - Seamless chat window with Claude AI, opens in current buffer by default
- **⚡ Inline Actions** - Quick code fixes, explanations, refactoring, and test generation
- **📋 Inline Preview UI** - Telescope-style diff preview with Accept/Reject for inline actions (Git required)
- **📝 Natural Language Commands** - Use custom instructions for any code transformation
- **🔧 Slash Commands** - In-chat commands for context management, permissions, and settings
- **🛡️ Granular Permissions** - Fine-grained control over AI capabilities with allow/deny rules and patterns
- **🎨 Permission Builder** - Interactive UI for configuring tool permissions via `/permissions` command
- **💾 Session Persistence** - Save and resume chat sessions with full context and metadata
- **🎯 Smart Context** - Automatic file context detection from open buffers and manual additions
- **🌍 Multi-language Support** - Configure different languages for chat and inline actions
- **📊 Diff Viewer** - Visual diff display for AI-edited files with `gd` keybinding
- **🤖 Neovim Agent Tools** - Claude can directly control Neovim (read/write buffers, execute commands) via MCP integration
- **⚙️ Highly Configurable** - Flexible modes, models, permissions, and UI settings

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "shabaraba/vibing.nvim",
  dependencies = {
    -- Optional: for file browser integration
    "stevearc/oil.nvim",
  },
  build = "./build.sh",  -- Builds MCP server for Neovim integration
  config = function()
    require("vibing").setup({
      -- Default configuration
      chat = {
        window = {
          position = "current",  -- "current" | "right" | "left" | "float"
          width = 0.4,
          border = "rounded",
        },
        auto_context = true,
        save_location_type = "project",  -- "project" | "user" | "custom"
        context_position = "append",  -- "prepend" | "append"
      },
      agent = {
        default_mode = "code",  -- "code" | "plan" | "explore"
        default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
      },
      permissions = {
        mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
        allow = { "Read", "Edit", "Write", "Glob", "Grep" },
        deny = { "Bash" },
        rules = {},  -- Optional granular permission rules
      },
      preview = {
        enabled = false,  -- Enable diff preview UI (requires Git)
      },
      language = nil,  -- Optional: "ja" | "en" | { default = "ja", chat = "ja", inline = "en" }
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "shabaraba/vibing.nvim",
  run = "./build.sh",  -- Builds MCP server for Neovim integration
  config = function()
    require("vibing").setup()
  end,
}
```

## 🚀 Usage

### User Commands

| Command                               | Description                                                                       |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| `:VibingChat [file]`                  | Open chat window or saved chat file                                               |
| `:VibingToggleChat`                   | Toggle chat window (open/close)                                                   |
| `:VibingSlashCommands`                | Show slash command picker in chat                                                 |
| `:VibingContext [path]`               | Add file to context (or from oil.nvim if no path)                                 |
| `:VibingClearContext`                 | Clear all context                                                                 |
| `:VibingInline [action\|instruction]` | Rich UI picker (no args) or direct execution (with args). Tab completion enabled. |
| `:VibingInlineAction`                 | Alias of `:VibingInline` (for backward compatibility)                             |
| `:VibingCancel`                       | Cancel current request                                                            |

### Inline Actions

**Rich UI Picker (recommended):**

```vim
:'<,'>VibingInline
" Opens a split-panel UI:
" - Left: Action menu (fix, feat, explain, refactor, test)
"   Navigate with j/k or arrow keys, Tab to move to input
" - Right: Additional instruction input (optional)
"   Shift-Tab to move back to menu
" - Enter to execute, Esc/Ctrl-c to cancel
```

**Keybindings:**

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
:'<,'>VibingInline fix using async/await
:'<,'>VibingInline test with Jest mocks
```

**Natural Language Instructions:**

```vim
:'<,'>VibingInline "Convert this function to TypeScript"
:'<,'>VibingInline "Add error handling with try-catch"
:'<,'>VibingInline "Optimize this loop for performance"
```

### Inline Preview UI

When `preview.enabled = true` is set in configuration, inline actions display a Telescope-style
preview UI after execution (requires Git repository):

**Layout:**

Inline mode (3 panels):

```text
┌──────────────┬──────────────────────────────────────┐
│ Files (3)    │ Diff Preview                         │
│  > src/a.lua │  @@ -10,5 +10,8 @@                   │
│    src/b.lua │  -old line                           │
│    tests/*.lua  +new line                           │
├──────────────┴──────────────────────────────────────┤
│ Response: Modified 3 files successfully             │
└─────────────────────────────────────────────────────┘
```

Chat mode (2 panels):

```text
┌──────────────┬──────────────────────────────────────┐
│ Files (3)    │ Diff Preview                         │
│  > src/a.lua │  @@ -10,5 +10,8 @@                   │
│    src/b.lua │  -old line                           │
│    tests/*.lua  +new line                           │
└──────────────┴──────────────────────────────────────┘
```

**Keybindings:**

- `j`/`k` - Move cursor up/down (normal Neovim navigation)
- `<Enter>` - Select file at cursor position (in Files window)
- `<Tab>` - Cycle to next window (Files → Diff → Response → Files)
- `<Shift-Tab>` - Cycle to previous window
- `a` - Accept all changes (close preview, keep modifications)
- `r` - Reject all changes (revert all files using `git checkout HEAD`)
- `q`/`Esc` - Close preview (keep changes)

**Features:**

- Responsive layout (horizontal ≥120 columns, vertical <120 columns)
- Delta integration for enhanced diff highlighting (if available)
- Navigate through multiple modified files
- Accept/Reject individual or all changes
- Git-based revert functionality

### Slash Commands (in Chat)

| Command                   | Description                                                      |
| ------------------------- | ---------------------------------------------------------------- |
| `/context <file>`         | Add file to context                                              |
| `/clear`                  | Clear context                                                    |
| `/save`                   | Save current chat                                                |
| `/summarize`              | Summarize conversation                                           |
| `/mode <mode>`            | Set execution mode (auto/plan/code/explore)                      |
| `/model <model>`          | Set AI model (opus/sonnet/haiku)                                 |
| `/permissions` or `/perm` | Interactive permission builder - configure tool allow/deny rules |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args          |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args           |

### Chat Keybindings

In chat buffers, the following keybindings are available:

| Key  | Description                                                                      |
| ---- | -------------------------------------------------------------------------------- |
| `gd` | Show diff for file under cursor (in Modified Files section)                      |
| `gf` | Open file under cursor (in Modified Files section)                               |
| `gp` | **Preview all modified files** - Opens Telescope-style preview UI (requires Git) |
| `q`  | Close chat window                                                                |

**Preview All Modified Files (`gp`):**

When Claude modifies multiple files in a chat session, press `gp` anywhere in the chat buffer to open
the inline preview UI showing all modified files at once. This provides the same Accept/Reject
functionality as inline actions:

- Navigate between files with `j`/`k`
- Press `a` to accept all changes
- Press `r` to reject and revert all changes (via `git checkout HEAD`)
- Press `q` to quit preview

## ⚙️ Configuration Examples

### Basic Setup

```lua
require("vibing").setup()
```

If you don't provide any configuration, the following **default permissions** will be applied:

```lua
permissions = {
  mode = "acceptEdits",  -- Auto-accept file edits, ask for other tools
  allow = {
    "Read",    -- Read files
    "Edit",    -- Edit files
    "Write",   -- Write new files
    "Glob",    -- Search files by pattern
    "Grep",    -- Search file contents
  },
  deny = {
    "Bash",    -- Block shell commands (security)
  },
}
```

These defaults are used as a **template** when creating new chat files. Each chat file's frontmatter
contains its own permissions, which are used at runtime.

### Custom Configuration

```lua
require("vibing").setup({
  chat = {
    window = {
      position = "float",
      width = 0.6,
      border = "single",
    },
    save_location_type = "user",  -- Global chat history
  },
  agent = {
    default_mode = "plan",  -- Start in planning mode
    default_model = "opus",  -- Use most capable model
  },
  permissions = {
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "WebSearch" },
    deny = {},  -- Allow all tools
  },
  preview = {
    enabled = true,  -- Enable diff preview UI
  },
  keymaps = {
    send = "<C-CR>",  -- Custom send key
    cancel = "<C-c>",
    add_context = "<C-a>",
  },
})
```

### Project-Specific Settings

```lua
-- Store chats in project directory
require("vibing").setup({
  chat = {
    save_location_type = "project",  -- .vibing/chat/ in project root
  },
})
```

### Custom Save Location

```lua
require("vibing").setup({
  chat = {
    save_location_type = "custom",
    save_dir = "~/my-ai-chats/vibing/",
  },
})
```

### Granular Permission Rules

```lua
require("vibing").setup({
  permissions = {
    mode = "default",  -- Ask for confirmation each time
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
        paths = { ".env", "*.secret" },
        action = "deny",
        message = "Cannot modify sensitive files",
      },
      -- Allow specific npm commands only
      {
        tools = { "Bash" },
        commands = { "npm", "yarn" },
        action = "allow",
      },
      -- Deny dangerous bash patterns
      {
        tools = { "Bash" },
        patterns = { "^rm -rf", "^sudo" },
        action = "deny",
        message = "Dangerous command blocked",
      },
    },
  },
})
```

### Multi-language Configuration

```lua
require("vibing").setup({
  -- Simple: All responses in Japanese
  language = "ja",

  -- Advanced: Different languages for chat and inline
  -- language = {
  --   default = "ja",
  --   chat = "ja",     -- Chat in Japanese
  --   inline = "en",   -- Inline actions in English
  -- },
})
```

## 📚 Configuration Reference

Complete reference of all configuration options:

### Agent Settings

Controls Claude Agent SDK behavior:

```lua
agent = {
  default_mode = "code",    -- Default execution mode
                            -- "code": Direct implementation
                            -- "plan": Plan first, then implement
                            -- "explore": Explore and analyze codebase

  default_model = "sonnet", -- Default Claude model
                            -- "sonnet": Balanced (recommended)
                            -- "opus": Most capable
                            -- "haiku": Fastest
}
```

### Chat Settings

Chat window and session configuration:

```lua
chat = {
  window = {
    position = "current",  -- Window position
                          -- "current": Open in current window
                          -- "right": Right vertical split
                          -- "left": Left vertical split
                          -- "float": Floating window

    width = 0.4,          -- Window width (0-1: ratio, >1: absolute columns)
    border = "rounded",   -- Border style: "rounded" | "single" | "double" | "none"
  },

  auto_context = true,     -- Automatically add open buffers to context

  save_location_type = "project",  -- Chat file save location
                                   -- "project": .vibing/chat/ in project root
                                   -- "user": ~/.local/share/nvim/vibing/chats/
                                   -- "custom": Use save_dir path

  save_dir = "~/.local/share/nvim/vibing/chats",  -- Used when save_location_type="custom"

  context_position = "append",  -- Where to add new context files
                               -- "append": Add to end of context list
                               -- "prepend": Add to beginning
}
```

### Permissions

Control what tools Claude can use. See [Granular Permission Rules](#granular-permission-rules) for
detailed examples.

```lua
permissions = {
  mode = "acceptEdits",  -- Permission mode
                        -- "default": Ask for confirmation each time
                        -- "acceptEdits": Auto-approve Edit/Write (recommended)
                        -- "bypassPermissions": Auto-approve all (use with caution)

  allow = {              -- Tools to allow (empty = allow all except denied)
    "Read",              -- Read files
    "Edit",              -- Edit existing files
    "Write",             -- Create new files
    "Glob",              -- Search files by pattern
    "Grep",              -- Search file contents
    -- "Bash",           -- Execute shell commands (security risk)
    -- "WebSearch",      -- Search the web
    -- "WebFetch",       -- Fetch web pages
  },

  deny = {               -- Tools to deny (takes precedence over allow)
    "Bash",              -- Block shell commands by default
  },

  rules = {},            -- Advanced: Granular permission rules
                        -- See Granular Permission Rules section
}
```

### Keymaps

Chat buffer key bindings:

```lua
keymaps = {
  send = "<CR>",         -- Send message
  cancel = "<C-c>",      -- Cancel current request
  add_context = "<C-a>", -- Add file to context
  open_diff = "gd",      -- Open diff viewer on file paths
  open_file = "gf",      -- Open file on file paths
}
```

### Preview Settings

Configure diff preview UI for inline actions and chat:

```lua
preview = {
  enabled = false,  -- Enable Telescope-style diff preview UI
                    -- Requires Git repository
                    -- Shows Accept/Reject UI after code modifications
                    -- Uses git diff and git checkout for revert
                    -- Works in both inline actions and chat (gp key)
}
```

### MCP (Model Context Protocol)

Enable Claude to directly control Neovim:

```lua
mcp = {
  enabled = false,               -- Enable MCP integration
  rpc_port = 9876,              -- RPC server port
  auto_setup = false,           -- Auto-build MCP server on plugin install
  auto_configure_claude_json = false,  -- Auto-configure ~/.claude.json
}
```

**What is `auto_configure_claude_json`?**

When enabled, automatically adds vibing.nvim MCP server to `~/.claude.json`:

```json
{
  "mcpServers": {
    "vibing-nvim": {
      "command": "node",
      "args": ["/path/to/vibing.nvim/mcp-server/dist/index.js"],
      "env": { "VIBING_RPC_PORT": "9876" }
    }
  }
}
```

This allows Claude Code CLI to control your Neovim instance (read/write buffers, execute commands).

**Recommended for lazy.nvim:**

```lua
{
  "shabaraba/vibing.nvim",
  build = "./build.sh",
  config = function()
    require("vibing").setup({
      mcp = {
        enabled = true,
        auto_setup = true,              -- Build on install
        auto_configure_claude_json = true,  -- Auto-configure
      },
    })
  end,
}
```

### Language

Configure AI response language:

```lua
-- Simple: All responses in one language
language = "ja"  -- or "en", "fr", etc.

-- Advanced: Different languages per context
language = {
  default = "ja",  -- Default language
  chat = "ja",     -- Chat window responses
  inline = "en",   -- Inline action responses
}
```

### Remote Control

For testing and development (advanced):

```lua
remote = {
  socket_path = nil,   -- Auto-detect from NVIM env variable
  auto_detect = true,  -- Enable remote control detection
}
```

## 📝 Chat File Format

Chats are saved as Markdown with YAML frontmatter for session resumption and configuration:

```yaml
---
vibing.nvim: true
session_id: <sdk-session-id>
created_at: 2024-01-01T12:00:00
mode: code  # auto | plan | code | explore
model: sonnet  # sonnet | opus | haiku
permissions_mode: acceptEdits  # default | acceptEdits | bypassPermissions
permissions_allow:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
permissions_deny:
  - Bash
language: ja  # Optional: default language for AI responses
---
# Vibing Chat

## User

Hello, Claude!

## Assistant

Hello! How can I help you today?
```

**Key Features:**

- **Session Resumption**: Automatically resumes conversation using `session_id`
- **Configuration Tracking**: Records mode, model, and permissions for transparency
- **Language Support**: Optional `language` field for consistent AI response language
- **Auditability**: All permissions are visible in frontmatter

## 🏗️ Architecture

For detailed architecture documentation, see [CLAUDE.md](./CLAUDE.md).

**Key Components:**

- **Agent SDK Integration** - Node.js wrapper communicating via JSON Lines
- **Agent SDK Adapter** - Claude Agent SDK for AI interactions
- **Context System** - Automatic and manual file context management
- **Session Persistence** - Resume conversations with full history

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📄 License

MIT License - see LICENSE file for details

## 🔗 Links

- [Claude AI](https://claude.ai)
- [Claude Agent SDK](https://github.com/anthropics/anthropic-sdk-typescript)
- [GitHub Repository](https://github.com/shabaraba/vibing.nvim)

---

Made with ❤️ using Claude Code
