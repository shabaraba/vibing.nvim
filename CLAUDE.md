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

- `ui/chat_buffer.lua` - Chat window with Markdown rendering, session persistence, diff viewer
- `ui/output_buffer.lua` - Read-only output for inline actions
- `ui/inline_progress.lua` - Progress window for inline code modifications
- `ui/permission_builder.lua` - Interactive permission configuration UI

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
mode: code # auto, plan, code, or explore (from config.agent.default_mode)
model: sonnet # sonnet, opus, or haiku (from config.agent.default_model)
permissions_mode: acceptEdits # default, acceptEdits, or bypassPermissions
permissions_allow:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
permissions_deny:
  - Bash
language: ja # Optional: default language for AI responses
---
```

When reopening a saved chat (`:VibingOpenChat` or `:e`), the session resumes via the stored `session_id`. The `mode` and `model` fields are automatically populated from `config.agent.default_mode` and `config.agent.default_model` on chat creation, and can be changed via `/mode` and `/model` slash commands. Configured permissions are recorded in frontmatter for transparency and auditability. The optional `language` field ensures consistent AI response language across sessions.

### Permissions Configuration

vibing.nvim provides comprehensive permission control over what tools Claude can use:

#### Permission Modes

```lua
require("vibing").setup({
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
  },
})
```

**Permission Modes:**

- `default` - Ask for user confirmation before each tool use
- `acceptEdits` - Auto-approve Edit/Write operations, ask for others (recommended)
- `bypassPermissions` - Auto-approve all operations (use with caution)

**Basic Permission Logic:**

- Deny list takes precedence over allow list
- If allow list is specified, only those tools are permitted
- If allow list is empty, all tools except denied ones are allowed
- Denied tools will return an error message when Claude attempts to use them

**Available Tools:** Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch

#### Granular Permission Rules

For fine-grained control, use permission rules based on paths, commands, patterns, or domains:

```lua
require("vibing").setup({
  permissions = {
    mode = "default",
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
        paths = { ".env", "*.secret", "*.key" },
        action = "deny",
        message = "Cannot modify sensitive files",
      },
      -- Allow specific npm/yarn commands
      {
        tools = { "Bash" },
        commands = { "npm", "yarn" },
        action = "allow",
      },
      -- Deny dangerous bash patterns
      {
        tools = { "Bash" },
        patterns = { "^rm -rf", "^sudo", "^dd if=" },
        action = "deny",
        message = "Dangerous command blocked",
      },
      -- Allow specific domains for web tools
      {
        tools = { "WebFetch", "WebSearch" },
        domains = { "github.com", "*.npmjs.com", "docs.rs" },
        action = "allow",
      },
    },
  },
})
```

**Rule Fields:**

- `tools` - Array of tool names to apply the rule to
- `paths` - Glob patterns for file paths (Read/Write/Edit)
- `commands` - Array of allowed/denied command names (Bash)
- `patterns` - Regex patterns for command matching (Bash)
- `domains` - Domain patterns for web requests (WebFetch/WebSearch)
- `action` - "allow" or "deny"
- `message` - Custom error message (optional, for deny rules)

#### Interactive Permission Builder

Use the `/permissions` (or `/perm`) slash command in chat to interactively configure permissions:

```
/permissions
```

This launches an interactive UI that guides you through:

1. Selecting a tool (Read, Edit, Write, Bash, etc.)
2. Choosing allow or deny
3. Optionally specifying Bash command patterns
4. Automatically updating chat frontmatter

The Permission Builder provides a user-friendly alternative to manually editing configuration or frontmatter.

### Key Patterns

**Adapter Pattern:** All AI backends implement the `Adapter` interface with `execute()`, `stream()`, `cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for selections.

**Permission System:** Three-layer permission control:

1. **Allow/Deny Lists** - Basic tool-level permissions
2. **Permission Modes** - Automation level (default/acceptEdits/bypassPermissions)
3. **Granular Rules** - Path/command/pattern/domain-based fine-grained control

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration, automatically updating chat frontmatter without manual YAML editing.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language globally or per-action (chat vs inline), supporting multi-language development workflows.

**Remote Control:** The `remote.lua` module provides socket-based communication with another Neovim instance. When Neovim is started with `--listen /tmp/nvim.sock`, the plugin can send commands, evaluate expressions, and retrieve buffer content from that instance. This enables AI-assisted editing of files in a separate Neovim session.

## Configuration

Example configuration showing all available settings:

```lua
require("vibing").setup({
  adapter = "agent_sdk",  -- Recommended: "agent_sdk" | "claude" | "claude_acp"
  agent = {
    default_mode = "code",    -- "code" | "plan" | "explore"
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
  },
  chat = {
    window = {
      position = "current",  -- "current" | "right" | "left" | "float"
      width = 0.4,
      border = "rounded",
    },
    auto_context = true,
    save_location_type = "project",  -- "project" | "user" | "custom"
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",  -- Used when "custom"
    context_position = "append",  -- "prepend" | "append"
  },
  inline = {
    default_action = "fix",  -- "fix" | "feat" | "explain" | "refactor" | "test"
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",  -- Open diff viewer on file paths
    open_file = "gf",  -- Open file on file paths
  },
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
    rules = {},  -- Optional granular rules
  },
  language = nil,  -- Optional: "ja" | "en" | { default = "ja", chat = "ja", inline = "en" }
  remote = {
    socket_path = nil,  -- Auto-detect from NVIM env variable
    auto_detect = true,
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

| Command                   | Description                                                 |
| ------------------------- | ----------------------------------------------------------- |
| `/context <file>`         | Add file to context                                         |
| `/clear`                  | Clear context                                               |
| `/save`                   | Save current chat                                           |
| `/summarize`              | Summarize conversation                                      |
| `/mode <mode>`            | Set execution mode (auto/plan/code/explore)                 |
| `/model <model>`          | Set AI model (opus/sonnet/haiku)                            |
| `/permissions` or `/perm` | Interactive Permission Builder - configure tool permissions |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args     |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args      |
| `/permission [mode]`      | Set permission mode (default/acceptEdits/bypassPermissions) |

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
