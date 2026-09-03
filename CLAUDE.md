# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

vibing.nvim is a Neovim plugin that provides a Claude chat inside Neovim by spawning the `claude`
CLI directly (`claude -p --output-format stream-json`) and parsing its stream. There is no
Node.js agent wrapper process; the Node side is only the MCP server and two hook scripts.
A Codex CLI backend is also supported. See
`.claude/rules/architecture.md`.

## Commands

```bash
# Install dependencies
npm install

# Build the MCP server
./build.sh

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

| File                    | Contents                                                                   |
| ----------------------- | -------------------------------------------------------------------------- |
| `architecture.md`       | 不変条件とモジュール地図。詳細は `handbook/architecture/` に外出し（下表） |
| `mcp-integration.md`    | MCP tools, usage examples, setup instructions                              |
| `permissions.md`        | Permission system, granular rules, Tool Approval UI                        |
| `self-development.md`   | Guidelines for developing vibing.nvim with vibing.nvim                     |
| `self-testing.md`       | E2E testing procedures, 3-try auto-fix rule, test helper reference         |
| `features.md`           | Auto-resume on usage limit, message timestamps, AskUserQuestion support    |
| `configuration.md`      | Full configuration examples, window positions, daily summary               |
| `commands-reference.md` | User commands, slash commands                                              |
| `web-workflow.md`       | Claude Code on the Web: SessionStart env setup, git push reqs              |

All `.md` files in `.claude/rules/` are automatically loaded into Claude Code's context. **だから
`.claude/rules/` に置くのは「放っておくと破る不変条件」と「どこに何があるかの地図」だけにする。**
理由・実測値・却下した代替案は必要になったときに読めばよいので、`handbook/architecture/` に置いて
ルール側からは1行で指す。

| 深掘り用（自動ロードされない）                 | Contents                                                |
| ---------------------------------------------- | ------------------------------------------------------- |
| `handbook/architecture/cli-integration.md`     | フックの protocol、バックエンド seams、各 CLI での実測  |
| `handbook/architecture/lightweight-calls.md`   | 軽量呼び出しをバックエンド別にどう制限しているか        |
| `handbook/architecture/plugin-and-commands.md` | `--plugin-dir`、スラッシュコマンド探索、起動コスト      |
| `handbook/architecture/per-request-diffs.md`   | git tree snapshot の詳細、overlap ガード、fallback 経路 |
| `handbook/architecture/chat-lineage.md`        | 並行実行、fork、subagent chat のセッション設計          |
| `handbook/architecture/orchestration.md`       | 完了通知の状態機械、キュー、round-trip 上限、tree 操作  |
| `handbook/architecture/session-persistence.md` | `working_dir` の git root 境界チェック                  |

## Repository Layout

Claude Code に配布されるものは**すべて `claude-plugin/` 配下**にある。リポジトリルートは
marketplace root（`.claude-plugin/marketplace.json` があるディレクトリ）で、plugin root は
その1階層下という関係になっている。

ただし通常の経路はもう marketplace ではない。`claude-plugin/` は
`cli_command_builder` が `--plugin-dir` でセッションごとに CLI に渡す（#618、
`.claude/rules/architecture.md` →「Plugin Loading, Command Discovery and Startup Cost」）。
marketplace.json は手動 `claude plugin install` のために残してあるだけ。

| 場所                                       | 中身                                                   |
| ------------------------------------------ | ------------------------------------------------------ |
| `.claude-plugin/marketplace.json`          | marketplace 定義。`source` が `./claude-plugin` を指す |
| `claude-plugin/.claude-plugin/plugin.json` | plugin 定義。`${CLAUDE_PLUGIN_ROOT}` はここの親        |
| `claude-plugin/{agents,skills}/`           | **配布される** サブエージェント・スキル                |
| `claude-plugin/mcp-server/`                | 配布される MCP サーバー                                |
| `.claude/{skills,commands,rules}/`         | **このリポジトリを開発するため**のもの。配布されない   |

`claude-plugin/` に置いたものは `--plugin-dir` 経由でユーザーに届き、`.claude/` に置いた
ものは届かない。スキルを追加するときはどちらの読者向けかで置き場所を決める。

ディレクトリ名が `plugin/` でないのは Neovim の予約名だからで、`plugin/**/*.lua` は
runtimepath 上で毎起動時に自動 source される（`:h load-plugins`）。`node_modules` を含む
ツリーをそこに置くと起動のたびに全走査される。

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
