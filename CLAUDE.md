# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

vibing.nvim is a Neovim plugin that integrates Claude AI through the Agent SDK. It provides chat and inline code actions within Neovim.

## Commands

```bash
# Install dependencies
npm install

# Test Agent SDK wrapper directly
node bin/agent-wrapper.mjs --prompt "Say hello" --cwd $(pwd)
```

For Neovim testing, load the plugin and run `:VibingChat`.

## Architecture

### Communication Flow

```
Neovim (Lua) → vim.system() → Node.js wrapper → Claude Agent SDK
                    ↑
            JSON Lines protocol
```

The Node.js wrapper (`bin/agent-wrapper.mjs`) outputs streaming responses as JSON Lines:
- `{"type": "session", "session_id": "..."}` - Session identifier for resumption
- `{"type": "chunk", "text": "..."}` - Streamed text content
- `{"type": "done"}` - Completion signal
- `{"type": "error", "message": "..."}` - Error messages

### Module Structure

**Core:**
- `lua/vibing/init.lua` - Entry point, command registration
- `lua/vibing/config.lua` - Configuration with type annotations

**Adapters (pluggable backends):**
- `adapters/base.lua` - Abstract adapter interface
- `adapters/agent_sdk.lua` - Main adapter using Claude Agent SDK (recommended)
- `adapters/claude.lua`, `adapters/claude_acp.lua` - Alternative backends

**UI:**
- `ui/chat_buffer.lua` - Chat window with Markdown rendering, session persistence
- `ui/output_buffer.lua` - Read-only output for inline actions

**Context System:**
- `context/init.lua` - Context manager (manual + auto from open buffers)
- `context/collector.lua` - Collects `@file:path` formatted contexts

**Actions:**
- `actions/chat.lua` - Chat session orchestration
- `actions/inline.lua` - Quick actions (fix, feat, explain, refactor, test)

### Session Persistence

Chat files are saved as Markdown with YAML frontmatter:
```yaml
---
vibing.nvim: true
session_id: <sdk-session-id>
created_at: 2024-01-01T12:00:00
mode: code  # auto, plan, or code (from config.agent.default_mode)
model: sonnet  # sonnet, opus, or haiku (from config.agent.default_model)
permissions_allow:
  - Read
  - Edit
  - Write
permissions_deny:
  - Bash
---
```

When reopening a saved chat (`:VibingOpenChat` or `:e`), the session resumes via the stored `session_id`. The `mode` and `model` fields are automatically populated from `config.agent.default_mode` and `config.agent.default_model` on chat creation, and can be changed via `/mode` and `/model` slash commands. Configured permissions are recorded in frontmatter for transparency and auditability.

### Permissions Configuration

vibing.nvim allows fine-grained control over what tools Claude can use through the `permissions` configuration:

```lua
require("vibing").setup({
  permissions = {
    allow = {  -- Explicitly allowed tools
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
    },
    deny = {  -- Explicitly denied tools
      "Bash",  -- Deny shell command execution for security
    },
  },
})
```

**Permission Logic:**
- Deny list takes precedence over allow list
- If allow list is specified, only those tools are permitted
- If allow list is empty, all tools except denied ones are allowed
- Denied tools will return an error message when Claude attempts to use them

**Available Tools:** Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch

### Key Patterns

**Adapter Pattern:** All AI backends implement the `Adapter` interface with `execute()`, `stream()`, `cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for selections.

## Configuration

Example configuration showing default mode and model settings:

```lua
require("vibing").setup({
  adapter = "agent_sdk",  -- Recommended
  agent = {
    default_mode = "code",    -- "auto" | "plan" | "code" | "explore"
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
  },
  chat = {
    window = {
      position = "right",  -- "right" | "left" | "float"
      width = 0.4,
      border = "rounded",
    },
    auto_context = true,
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
  },
  inline = {
    default_action = "fix",  -- "fix" | "feat" | "explain"
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
  },
})
```

## User Commands

| Command | Description |
|---------|-------------|
| `:VibingChat` | Open chat window |
| `:VibingContext [path]` | Add file to context |
| `:VibingClearContext` | Clear all context |
| `:VibingInline [action]` | Run inline action on selection (fix/feat/explain/refactor/test) |
| `:VibingExplain` | Explain selected code |
| `:VibingFix` | Fix selected code issues |
| `:VibingFeature` | Implement feature in selected code |
| `:VibingRefactor` | Refactor selected code |
| `:VibingTest` | Generate tests for selected code |
| `:VibingCancel` | Cancel current request |
| `:VibingOpenChat <file>` | Open saved chat file |

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command | Description |
|---------|-------------|
| `/context <file>` | Add file to context |
| `/clear` | Clear context |
| `/save` | Save current chat |
| `/summarize` | Summarize conversation |
| `/mode <mode>` | Set execution mode (auto/plan/code) |
| `/model <model>` | Set AI model (opus/sonnet/haiku) |
