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
- `{"type": "tool_use", "tool": "Edit", "file_path": "..."}` - File modification event
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
- `ui/inline_progress.lua` - Progress window for inline code modifications

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
mode: code # auto, plan, or code (from config.agent.default_mode)
model: sonnet # sonnet, opus, or haiku (from config.agent.default_model)
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

**Remote Control:** The `remote.lua` module provides socket-based communication with another Neovim instance. When Neovim is started with `--listen /tmp/nvim.sock`, the plugin can send commands, evaluate expressions, and retrieve buffer content from that instance. This enables AI-assisted editing of files in a separate Neovim session.

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

| Command                          | Description                                                     |
| -------------------------------- | --------------------------------------------------------------- |
| `:VibingChat`                    | Open chat window                                                |
| `:VibingToggleChat`              | Toggle chat window (open/close)                                 |
| `:VibingContext [path]`          | Add file to context                                             |
| `:VibingClearContext`            | Clear all context                                               |
| `:VibingInline [action\|prompt]` | Run inline action or natural language instruction on selection  |
| `:VibingExplain [instruction]`   | Explain selected code (with optional additional instruction)    |
| `:VibingFix [instruction]`       | Fix selected code issues (with optional additional instruction) |
| `:VibingFeature [instruction]`   | Implement feature in selected code (with optional instruction)  |
| `:VibingRefactor [instruction]`  | Refactor selected code (with optional additional instruction)   |
| `:VibingTest [instruction]`      | Generate tests for selected code (with optional instruction)    |
| `:VibingCancel`                  | Cancel current request                                          |
| `:VibingOpenChat <file>`         | Open saved chat file                                            |
| `:VibingRemote <command>`        | Execute command in remote Neovim instance (requires `--listen`) |
| `:VibingRemoteStatus`            | Show remote Neovim status (mode, buffer, cursor position)       |
| `:VibingSendToChat`              | Send file from oil.nvim to chat (requires oil.nvim)             |

### Inline Action Examples

Predefined actions:

```vim
:'<,'>VibingInline fix       " Fix code issues
:'<,'>VibingInline feat      " Implement feature
:'<,'>VibingInline explain   " Explain code
:'<,'>VibingInline refactor  " Refactor code
:'<,'>VibingInline test      " Generate tests
```

With additional instructions:

```vim
:'<,'>VibingExplain 日本語で                    " Explain in Japanese
:'<,'>VibingFix using async/await               " Fix with specific style
:'<,'>VibingTest using Jest with mocks          " Generate tests with framework
:'<,'>VibingRefactor to use functional style    " Refactor with specific approach
```

Natural language instructions (via VibingInline):

```vim
:'<,'>VibingInline "Convert this function to TypeScript"
:'<,'>VibingInline "Add error handling with try-catch"
:'<,'>VibingInline "Optimize this loop for performance"
```

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command              | Description                                                 |
| -------------------- | ----------------------------------------------------------- |
| `/context <file>`    | Add file to context                                         |
| `/clear`             | Clear context                                               |
| `/save`              | Save current chat                                           |
| `/summarize`         | Summarize conversation                                      |
| `/mode <mode>`       | Set execution mode (auto/plan/code/explore)                 |
| `/model <model>`     | Set AI model (opus/sonnet/haiku)                            |
| `/allow [tool]`      | Add tool to allow list, or show list if no args             |
| `/deny [tool]`       | Add tool to deny list, or show list if no args              |
| `/permission [mode]` | Set permission mode (default/acceptEdits/bypassPermissions) |

## Claude Code on the Web

When developing with Claude Code on the web, there are specific Git push constraints that require special handling.

### Git Push Requirements

**Branch Naming:**

- Branch names MUST start with `claude/`
- Branch names MUST end with a matching session ID
- Example: `claude/feature-name-abc123`
- Pushing to non-compliant branches will fail with HTTP 403

**Retry Logic:**

- Network operations may experience transient failures
- Always use exponential backoff retry (2s, 4s, 8s, 16s)
- Maximum 4 retry attempts recommended

### Using the Git Workflow Skill

A comprehensive skill is available at `.claude/skills/git-remote-workflow/SKILL.md` that provides:

**Branch Management:**

- Branch name validation and conversion
- Pattern compliance checking (`claude/*-<sessionId>`)

**Push Operations:**

- Automatic retry with exponential backoff
- Force push handling with safety checks

**Pull Request Creation:**

- GitHub API integration (no `gh` CLI required)
- Multi-line PR descriptions with proper formatting
- Multiple PR creation in one session
- PR update capabilities

**Complete Workflows:**

- Feature development to PR creation
- Review comment resolution
- Multi-PR workflows

**Environment Detection:**

- Automatic detection of Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)
- Environment-specific logic application

**Quick reference:**

```bash
# Create compliant branch
git checkout -b "claude/my-feature-${CLAUDE_SESSION_ID:-9GOGf}"

# Push with retry
for i in 0 1 2 3; do
  [ $i -gt 0 ] && sleep $((2 ** i))
  git push -u origin "$(git branch --show-current)" && break
done

# Create PR via GitHub API
curl -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/owner/repo/pulls" \
  -d '{"title":"My PR","head":"claude/branch-abc","base":"main","body":"Description"}'
```

See `.claude/skills/git-remote-workflow/SKILL.md` for complete documentation, workflows, and troubleshooting.
