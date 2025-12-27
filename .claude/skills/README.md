# Claude Code Skills

This directory contains skills for Claude Code to provide specialized knowledge and workflows.

## Available Skills

### neovim-remote-control

**Location:** `.claude/skills/neovim-remote-control/SKILL.md`

Control remote Neovim instances via Unix socket for testing, development, and automation:

- **Socket Detection:** Auto-detect from `$NVIM` environment variable
- **Command Execution:** Send commands, evaluate expressions, get buffer state
- **E2E Testing:** Automate Neovim operations for testing workflows
- **Natural Language Control:** Respond to user requests like "open this file in Neovim"
- **Troubleshooting:** Common socket and communication issues

**When activated:** When user requests Neovim control or socket path is available

**Allowed tools:** Bash, Read

**Coverage:**

- `nvim --server --remote-send` for sending commands
- `nvim --server --remote-expr` for evaluating expressions
- Buffer content retrieval and manipulation
- Status checking (mode, buffer, cursor position)
- E2E testing workflows

### git-remote-workflow

**Location:** `.claude/skills/git-remote-workflow/SKILL.md`

Comprehensive Git workflow for Claude Code on the web environment with:

- **Branch Management:** Naming validation (`claude/*-<sessionId>` pattern), branch conversion
- **Push Operations:** Automatic retry with exponential backoff, force push handling
- **PR Creation:** GitHub API integration (no `gh` CLI dependency), multiple PR creation
- **Complete Workflows:** Feature development, review comment resolution, multi-PR workflows
- **Troubleshooting:** Common issues and solutions
- **Environment Detection:** Automatic detection of remote environment

**When activated:** Automatically when working with Git in Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)

**Allowed tools:** Bash, Read, Grep

**Coverage:**

- Git push with retry logic
- Pull request creation via GitHub API
- Branch naming compliance
- Multi-PR workflows
- Error handling and debugging

### nvim-dev-helper

**Location:** `.claude/skills/nvim-dev-helper/SKILL.md`

Neovim プラグイン開発に特化したサポート:

- **Lua API 最適化:** `vim.api.*` vs `vim.*` の適切な選択
- **非同期処理:** `vim.schedule`, `vim.loop` のベストプラクティス
- **テストとデバッグ:** plenary.nvim を使ったテスト作成
- **ドキュメント生成:** vimdoc 形式のヘルプ生成
- **MCP サーバー統合:** vibing-nvim MCP ツールの効果的な使用

**When activated:** vim.api, 非同期, バッファ, vimdoc などのキーワード検出時

**Allowed tools:** Read, Edit, Write, Glob, Grep

### lsp-integration

**Location:** `.claude/skills/lsp-integration/SKILL.md`

vibing.nvim の MCP サーバー経由で LSP を活用したコード分析:

- **バックグラウンド分析:** チャットから離れずに LSP 操作
- **型情報取得:** 定義、参照、診断情報の即座取得
- **呼び出し階層:** 関数の呼び出し関係の可視化
- **リファクタリング支援:** 影響範囲の事前分析

**When activated:** 型定義、エラー調査、参照確認などのリクエスト時

**Allowed tools:** mcp__vibing-nvim__* (all MCP tools)

### smart-code-review

**Location:** `.claude/skills/smart-code-review/SKILL.md`

LSP と静的解析を組み合わせた高度なコードレビュー:

- **構造的品質:** アーキテクチャパターン、依存関係の確認
- **パフォーマンス:** 非効率な処理の検出
- **セキュリティ:** 脆弱性のチェック
- **Neovim 固有:** プラグインパフォーマンスへの影響分析
- **保守性:** 複雑度、ネーミング、テストカバレッジ

**When activated:** レビュー、問題点指摘、改善提案などのリクエスト時

**Allowed tools:** Read, Grep, mcp__vibing-nvim__*

## How Skills Work

Skills are directories containing a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: skill-name
description: What this skill does and when to use it
allowed-tools: Bash, Read, Grep # Optional
---
# Skill Instructions

Clear, step-by-step guidance...
```

**Key components:**

- `name`: Lowercase, numbers, hyphens only (max 64 chars)
- `description`: Brief description for Claude to discover when to use (max 1024 chars)
- `allowed-tools`: Optional list of tools this skill can use without asking permission

Skills are activated automatically by Claude based on:

- Environment detection (`CLAUDE_CODE_REMOTE=true`)
- User requests matching the description
- Current task context

## Creating New Skills

To create a new skill:

1. Create a directory in `.claude/skills/`:

   ```bash
   mkdir -p .claude/skills/my-skill
   ```

2. Create `SKILL.md` with YAML frontmatter:

   ```yaml
   ---
   name: my-skill
   description: What it does and when to use it
   ---

   # My Skill

   ## Instructions
   Step-by-step guidance for Claude

   ## Examples
   Concrete usage examples
   ```

3. Optionally add support files:

   ```text
   my-skill/
   ├── SKILL.md (required)
   ├── reference.md (optional)
   └── scripts/
       └── helper.py (optional)
   ```

4. Update this README with the new skill

For detailed guidance, see [Claude Code Skills Documentation](https://docs.claude.com/ja/docs/agents-and-tools/agent-skills).

## Slash Commands

Slash commands are available in vibing.nvim chat sessions. Use them by typing `/` followed by the command name.

### Available Commands

| Command         | Description                                      | File                   |
| --------------- | ------------------------------------------------ | ---------------------- |
| `/refactor`     | リファクタリング提案（複雑度削減、関数分割など） | `commands/refactor.md` |
| `/analyze`      | ファイル/モジュールの詳細分析レポート            | `commands/analyze.md`  |
| `/vim-help`     | vimdoc 形式のヘルプドキュメント生成              | `commands/vim-help.md` |
| `/debug-issue`  | Issue のデバッグ                                 | `commands/debug-issue.md` |
| `/test-feature` | 機能テスト                                       | `commands/test-feature.md` |

### Built-in Commands

These commands are built into vibing.nvim:

| Command                 | Description                                   |
| ----------------------- | --------------------------------------------- |
| `/context <file>`       | ファイルをコンテキストに追加                  |
| `/clear`                | コンテキストクリア                            |
| `/save`                 | チャット保存                                  |
| `/summarize`            | 会話の要約                                    |
| `/mode <mode>`          | 実行モード変更（auto/plan/code/explore）      |
| `/model <model>`        | AI モデル変更（opus/sonnet/haiku）            |
| `/permissions` `/perm`  | パーミッション設定 UI                         |
| `/allow [tool]`         | ツールを許可リストに追加                      |
| `/deny [tool]`          | ツールを拒否リストに追加                      |
| `/permission [mode]`    | パーミッションモード設定                      |

### Usage Examples

**In chat:**

```text
# リファクタリング
/refactor

# 詳細分析
/analyze

# vimdoc 生成
/vim-help

# コンテキスト追加
/context lua/vibing/actions/chat.lua

# モード変更
/mode plan

# パーミッション設定
/permissions
```

## Recommended MCP Servers

To enhance vibing.nvim chat experience, consider adding these MCP servers to `~/.claude.json`:

### Essential

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/vibing.nvim"]
    },
    "git": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-git"]
    }
  }
}
```

### Enhanced Development

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "your-token-here"
      }
    },
    "sequential-thinking": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]
    }
  }
}
```

See `/tmp/recommended-mcp-servers.md` for detailed MCP server setup guide.

## Quick Start

1. **チャット開始:**
   ```vim
   :VibingChat
   ```

2. **スラッシュコマンド確認:**
   ```vim
   :VibingSlashCommands
   ```

3. **コード分析:**
   ```text
   /analyze
   ```

4. **LSP 活用:**
   ```text
   この関数の型定義を確認して
   → lsp-integration スキルが自動起動
   ```

5. **コードレビュー:**
   ```text
   このファイルをレビューして
   → smart-code-review スキルが自動起動
   ```
