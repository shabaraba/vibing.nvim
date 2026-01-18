# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

vibing.nvim is a Neovim plugin that integrates Claude AI through the Agent SDK.
It provides chat and inline code actions within Neovim.

## Commands

```bash
# Install dependencies
npm install

# Build TypeScript to JavaScript (production mode)
npm run build

# Build with watch mode (for development)
npm run build:watch

# Test Agent SDK wrapper directly
node dist/bin/agent-wrapper.js --prompt "Say hello" --cwd $(pwd)

# Run Lua tests (requires Neovim with plenary.nvim)
npm run test:lua

# Validate Lua syntax
npm run check

# Lint TypeScript/JavaScript
npm run lint

# Fix lint issues
npm run lint:fix

# Format code
npm run format

# Check formatting
npm run format:check

# Lint Markdown files
npm run lint:md
```

For Neovim testing, load the plugin and run `:VibingChat`.

## Development Mode

vibing.nvim supports two execution modes:

**Production Mode (default):**

- Uses compiled JavaScript from `dist/bin/agent-wrapper.js`
- Requires `npm run build` after code changes
- Faster startup time

**Development Mode:**

- Directly executes TypeScript from `bin/agent-wrapper.ts` using bun
- No build step required - changes take effect immediately
- Requires bun to be installed in PATH

**Enable via Lazy.nvim (recommended):**

```lua
return {
  "yourusername/vibing.nvim",
  dev = true,  -- Automatically enables dev_mode
  dir = "~/workspaces/nvim-plugins/vibing.nvim",
  config = function()
    require("vibing").setup({
      -- node.dev_mode is automatically set to true when dev = true
    })
  end,
}
```

**Manual enable:**

```lua
require("vibing").setup({
  node = {
    dev_mode = true,  -- Enable TypeScript direct execution with bun
  },
})
```

## Documentation Structure

Detailed documentation is organized in `.claude/rules/`:

| File                    | Contents                                                                        |
| ----------------------- | ------------------------------------------------------------------------------- |
| `architecture.md`       | Communication flow, module structure, session persistence, concurrent execution |
| `mcp-integration.md`    | MCP tools, usage examples, setup instructions                                   |
| `permissions.md`        | Permission system, granular rules, Tool Approval UI                             |
| `self-development.md`   | Guidelines for developing vibing.nvim with vibing.nvim                          |
| `features.md`           | Message timestamps, AskUserQuestion support                                     |
| `configuration.md`      | Full configuration examples, window positions                                   |
| `commands-reference.md` | User commands, inline actions, slash commands                                   |
| `web-workflow.md`       | Claude Code on the Web git push requirements                                    |

All `.md` files in `.claude/rules/` are automatically loaded into Claude Code's context.
