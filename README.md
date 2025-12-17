# vibing.nvim

[![CI](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/shabaraba/vibing.nvim)](https://github.com/shabaraba/vibing.nvim/releases)

A Neovim plugin that integrates Claude AI through the Agent SDK, providing intelligent chat and inline code actions directly within your editor.

## Table of Contents

- [Features](#-features)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration Examples](#️-configuration-examples)
- [Remote Control](#-remote-control)
- [Chat File Format](#-chat-file-format)
- [Architecture](#️-architecture)
- [Contributing](#-contributing)
- [License](#-license)
- [Links](#-links)

## ✨ Features

- **💬 Chat Interface** - Interactive chat window with Claude AI
- **⚡ Inline Actions** - Quick code fixes, explanations, refactoring, and more
- **📝 Natural Language Commands** - Use custom instructions for any code transformation
- **🔧 Slash Commands** - In-chat commands for context management and settings
- **💾 Session Persistence** - Save and resume chat sessions with full context
- **🎯 Smart Context** - Automatic file context detection and manual additions
- **🔌 Remote Control** - Control Neovim instances via `--listen` socket
- **🎨 Configurable** - Flexible permissions, modes, and UI settings

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "shabaraba/vibing.nvim",
  dependencies = {
    -- Optional: for file browser integration
    "stevearc/oil.nvim",
  },
  build = "npm install",
  config = function()
    require("vibing").setup({
      -- Default configuration
      adapter = "agent_sdk",  -- "agent_sdk" | "claude" | "claude_acp"
      chat = {
        window = {
          position = "right",  -- "right" | "left" | "float"
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
        allow = { "Read", "Edit", "Write", "Glob", "Grep" },
        deny = { "Bash" },
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "shabaraba/vibing.nvim",
  run = "npm install",
  config = function()
    require("vibing").setup()
  end,
}
```

## 🚀 Usage

### User Commands

| Command                               | Description                                            |
| ------------------------------------- | ------------------------------------------------------ |
| `:VibingChat`                         | Open chat window                                       |
| `:VibingContext [path]`               | Add file to context                                    |
| `:VibingClearContext`                 | Clear all context                                      |
| `:VibingInline [action\|instruction]` | Run action or custom instruction on selection          |
| `:VibingExplain`                      | Explain selected code                                  |
| `:VibingFix`                          | Fix selected code issues                               |
| `:VibingFeature`                      | Implement feature in selected code                     |
| `:VibingRefactor`                     | Refactor selected code                                 |
| `:VibingTest`                         | Generate tests for selected code                       |
| `:VibingCustom <instruction>`         | Execute custom instruction on code                     |
| `:VibingCancel`                       | Cancel current request                                 |
| `:VibingOpenChat <file>`              | Open saved chat file                                   |
| `:VibingRemote <command>`             | Execute command in remote Neovim (requires `--listen`) |
| `:VibingRemoteStatus`                 | Show remote Neovim status                              |
| `:VibingSendToChat`                   | Send file from oil.nvim to chat                        |
| `:VibingMigrate`                      | Migrate chat files to new format                       |

### Inline Actions

**Predefined actions:**

```vim
:'<,'>VibingInline fix       " Fix code issues
:'<,'>VibingInline feat      " Implement feature
:'<,'>VibingInline explain   " Explain code
:'<,'>VibingInline refactor  " Refactor code
:'<,'>VibingInline test      " Generate tests
```

**Natural language instructions:**

```vim
:'<,'>VibingInline "Convert this function to TypeScript"
:'<,'>VibingInline "Add error handling with try-catch"
:'<,'>VibingCustom "Optimize this loop for performance"
```

### Slash Commands (in Chat)

| Command           | Description                         |
| ----------------- | ----------------------------------- |
| `/context <file>` | Add file to context                 |
| `/clear`          | Clear context                       |
| `/save`           | Save current chat                   |
| `/summarize`      | Summarize conversation              |
| `/mode <mode>`    | Set execution mode (auto/plan/code) |
| `/model <model>`  | Set AI model (opus/sonnet/haiku)    |

## ⚙️ Configuration Examples

### Basic Setup

```lua
require("vibing").setup()
```

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

## 🔌 Remote Control

Control Neovim instances via socket:

```bash
# Start Neovim with remote control
nvim --listen /tmp/nvim.sock

# In another Neovim instance
:VibingRemote "edit ~/.config/nvim/init.lua"
:VibingRemoteStatus
```

## 📝 Chat File Format

Chats are saved as Markdown with YAML frontmatter:

```yaml
---
vibing.nvim: true
session_id: <sdk-session-id>
created_at: 2024-01-01T12:00:00
mode: code
model: sonnet
permissions_allow:
  - Read
  - Edit
permissions_deny:
  - Bash
---
# Vibing Chat

## User

Hello, Claude!
```

## 🏗️ Architecture

For detailed architecture documentation, see [CLAUDE.md](./CLAUDE.md).

**Key Components:**

- **Agent SDK Integration** - Node.js wrapper communicating via JSON Lines
- **Adapter Pattern** - Pluggable backends (agent_sdk, claude, claude_acp)
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
