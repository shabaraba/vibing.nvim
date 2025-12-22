<div align="center">

<img src=".github/assets/logo.png" alt="vibing.nvim logo" width="200"/>

# vibing.nvim

**Intelligent AI-Powered Code Assistant for Neovim**

[![CI](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/shabaraba/vibing.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/shabaraba/vibing.nvim)](https://github.com/shabaraba/vibing.nvim/releases)

A powerful Neovim plugin that seamlessly integrates **Claude AI** through the Agent SDK, bringing intelligent chat conversations and context-aware inline code actions directly into your editor.

[Features](#-features) • [Installation](#-installation) • [Usage](#-usage) • [Configuration](#️-configuration) • [Contributing](#-contributing)

</div>

---

## Table of Contents

- [Features](#-features)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration Examples](#️-configuration-examples)
- [Chat File Format](#-chat-file-format)
- [Architecture](#️-architecture)
- [Contributing](#-contributing)
- [License](#-license)
- [Links](#-links)

## ✨ Features

- **💬 Interactive Chat Interface** - Seamless chat window with Claude AI, opens in current buffer by default
- **⚡ Inline Actions** - Quick code fixes, explanations, refactoring, and test generation
- **📝 Natural Language Commands** - Use custom instructions for any code transformation
- **🔧 Slash Commands** - In-chat commands for context management, permissions, and settings
- **🛡️ Granular Permissions** - Fine-grained control over AI capabilities with allow/deny rules and patterns
- **🎨 Permission Builder** - Interactive UI for configuring tool permissions via `/permissions` command
- **💾 Session Persistence** - Save and resume chat sessions with full context and metadata
- **🎯 Smart Context** - Automatic file context detection from open buffers and manual additions
- **🌍 Multi-language Support** - Configure different languages for chat and inline actions
- **📊 Diff Viewer** - Visual diff display for AI-edited files with `gd` keybinding
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
  build = "npm install",
  config = function()
    require("vibing").setup({
      -- Default configuration
      adapter = "agent_sdk",  -- "agent_sdk" | "claude" | "claude_acp"
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
      language = nil,  -- Optional: "ja" | "en" | { default = "ja", chat = "ja", inline = "en" }
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
