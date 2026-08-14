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

# Run agent behavior evals (spends real tokens — see tests/evals/README.md)
npm run test:eval

# Validate Lua syntax
npm run check

# Verify doc/*.txt (helptags, 78-column limit, CONTENTS/tag agreement)
npm run check:doc

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

`lua/vibing/core/constants/tools.lua` がツール名の唯一の定義元。`lua/vibing/config.lua` と
`can_use_tool.lua` は値を再列挙せずここを参照する。

- **`VALID_TOOLS`**: 権限設定に書けるツール名の一覧。権限バリデーション（未知ツール名の警告）に使う
- **`DEFAULT_ALLOWED_TOOLS`**: `permissions.allow` の既定値。`VALID_TOOLS` からの差集合としては
  導出しない（理由は同ファイルのコメント参照）
- **`ALWAYS_ALLOWED_TOOLS`**: `allow` の内容に関わらず（`ask` / `deny` に無い限り）常に許可される
  下限。`DEFAULT_ALLOWED_TOOLS` から外しても、こちらに残っていれば許可されたままになる。基準は
  「ファイルを作成・更新・削除しない読み取り専用のビルトインツール」（`Read` / `Glob` / `Grep` など）。
  ユーザーが `ask` / `deny` で上書きできる点が下の `INTERNAL_TOOLS` との違い
- **`INTERNAL_TOOLS`**: `ToolSearch` / `TodoWrite` / `ReportFindings` / `ScheduleWakeup` など、
  Claude Code ハーネス内部の副作用なし制御ツール。`ask` / `deny` すら通さず常に許可される
  （`can_use_tool.lua` の評価順で `ALWAYS_ALLOWED_TOOLS` より前）。`VALID_TOOLS` への登録は不要。
  定義は `tools.lua`（判定は `INTERNAL_TOOLS_MAP` を参照）
- 新しいツールを追加するとき: 既定で許可するなら `VALID_TOOLS` と `DEFAULT_ALLOWED_TOOLS` の
  両方に、Bash のように既定では許可しないなら `VALID_TOOLS` にのみ足す
