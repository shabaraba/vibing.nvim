# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

vibing.nvim is a Neovim plugin that provides a Claude chat inside Neovim by spawning the `claude`
CLI directly (`claude -p --output-format stream-json`) and parsing its stream. There is no
Node.js agent wrapper process; the Node side is only the MCP server, two hook scripts, and a
slash-command lister. A Codex CLI backend is also supported. See
`.claude/rules/architecture.md`.

## Commands

```bash
# Install dependencies
npm install

# Build the Node.js side (MCP server + bin/list-commands.ts) into dist/
npm run build

# Build with watch mode (for development)
npm run build:watch

# Run Lua tests (requires Neovim with plenary.nvim)
npm run test:lua

# Run Node.js tests (tests/**/*.test.mjs)
npm run test:node

# Run E2E tests
npm run test:e2e

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

## Documentation Structure

Detailed documentation is organized in `.claude/rules/`:

| File                    | Contents                                                                        |
| ----------------------- | ------------------------------------------------------------------------------- |
| `architecture.md`       | Communication flow, module structure, session persistence, concurrent execution |
| `mcp-integration.md`    | MCP tools, usage examples, setup instructions                                   |
| `permissions.md`        | Permission system, granular rules, Tool Approval UI                             |
| `self-development.md`   | Guidelines for developing vibing.nvim with vibing.nvim                          |
| `self-testing.md`       | E2E testing procedures, 3-try auto-fix rule, test helper reference              |
| `features.md`           | Auto-resume on usage limit, message timestamps, AskUserQuestion support         |
| `configuration.md`      | Full configuration examples, window positions, daily summary                    |
| `commands-reference.md` | User commands, slash commands                                                   |
| `web-workflow.md`       | Claude Code on the Web git push requirements                                    |

All `.md` files in `.claude/rules/` are automatically loaded into Claude Code's context.

## Development Rules

- **テストフィクスチャ・スキャフォルド**: ルートディレクトリに置かない。`tests/` 配下に配置すること
  - ✅ `tests/fixtures/`, `tests/e2e/`, `tests/lua/` など
  - ❌ `test-*/`, `test-xxx/` をリポジトリルートに作成しない

## Key Constants

- **有効ツール名リスト (`VALID_TOOLS`)**: `lua/vibing/core/constants/tools.lua`
  - 権限バリデーション（未知ツール名の警告）に使用
  - 新しいツールを追加する場合はここと `lua/vibing/config.lua` の `M.defaults.permissions.allow` の両方に追加する
