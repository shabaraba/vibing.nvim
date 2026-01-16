# Squad Naming System Specification

## Overview

vibing.nvimのチャットバッファにNATO phonetic alphabetに基づく分隊名を自動付与し、マルチエージェント協調の基盤を構築する。

関連Issue: #305

## NATO Phonetic Alphabet

```
Alpha, Bravo, Charlie, Delta, Echo, Foxtrot, Golf, Hotel,
India, Juliet, Kilo, Lima, Mike, November, Oscar, Papa,
Quebec, Romeo, Sierra, Tango, Uniform, Victor, Whiskey,
X-ray, Yankee, Zulu
```

## Roles

### Commander

- **判定条件**: カレントディレクトリが `.worktrees/` 配下でない
- **表示名**: `<Commander>`
- **責務**: タスク割り当て、進捗管理

### Squad (分隊)

- **判定条件**: カレントディレクトリが `.worktrees/` 配下
- **表示名**: `<Alpha>`, `<Bravo>`, ...
- **責務**: 割り当てられたタスクの実行

```lua
-- 判定ロジック
local function is_worktree()
  local cwd = vim.fn.getcwd()
  return cwd:match("/.worktrees/") ~= nil
end

local function get_role()
  return is_worktree() and "squad" or "commander"
end
```

## Message Header Format

### 基本フォーマット

| 送信元    | 送信先                       | 送信前                                   | 送信後                                       |
| --------- | ---------------------------- | ---------------------------------------- | -------------------------------------------- |
| User      | 自バッファ                   | `## User <!-- unsent -->`                | `## User <!-- {datetime} -->`                |
| Assistant | 自バッファ                   | -                                        | `## Assistant <{squad/Commander}>`           |
| Assistant | 他バッファ（メンション返信） | `## Assistant <{squad}> <!-- unsent -->` | `## Assistant <{squad}> <!-- {datetime} -->` |

### ヘッダー例

**Commander:**

```markdown
## User <!-- 2025-01-15 10:30:00 -->

Issue #123 を Alpha に割り当てて

## Assistant <Commander>

Issue #123 を Alpha 分隊に割り当てました。
@Alpha Issue #123 のログ機能実装をお願いします。
```

**Squad:**

```markdown
## User <!-- 2025-01-15 10:30:00 -->

ログ機能を実装して

## Assistant <Alpha>

了解しました。ログ機能を実装します...
```

**メンション返信（Alpha → Commander バッファ）:**

```markdown
## Assistant <Alpha> <!-- 2025-01-15 10:35:00 -->

了解しました。ログ機能を実装します...
```

### パース用正規表現

```lua
local patterns = {
  -- User（送信前）
  user_unsent = "^## User <!%-%- unsent %-%->$",
  -- User（送信後）
  user_sent = "^## User <!%-%- (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) %-%->$",

  -- Assistant（自バッファ）
  assistant_with_name = "^## Assistant <(%w+)>$",

  -- Assistant（他バッファへ送信・送信前）
  assistant_squad_unsent = "^## Assistant <(%w+)> <!%-%- unsent %-%->$",
  -- Assistant（他バッファへ送信・送信後）
  assistant_squad_sent = "^## Assistant <(%w+)> <!%-%- (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) %-%->$",
}
```

## Squad Name Assignment Rules

### 新規チャット作成時

```
[Commander]
  → squad_name = "Commander"
  → task_type = "commander"

[Squad + Issue紐付き（将来拡張）]
  → squad_assignments.json から既存割り当てを確認
  → 既存あり: その分隊名を使用（衝突時は一時変更）
  → 既存なし: 新規分隊名を割り当て、保存

[Squad + 単発タスク]
  → 未使用の分隊名を割り当て
  → squad_assignments.json には保存しない
  → task_type = "adhoc"
```

### 既存チャット再開時

```
1. frontmatter から squad_name を読み取り
2. 現在開いている全バッファの分隊名をチェック
3. 衝突判定:
   - 衝突なし → そのまま使用
   - 衝突あり → 未使用の分隊名を一時割り当て
                バッファに通知コメントを挿入
```

### 衝突時の通知

チャットバッファの末尾にコメントを追加：

```markdown
<!-- vibing.nvim: 分隊名 Alpha は既に使用中のため、Bravo として動作します -->
```

## Data Structures

### Frontmatter Extension

```yaml
---
vibing.nvim: true
session_id: abc123
squad_name: Alpha # 永続的な分隊名（Commander または NATO名）
task_ref: github:#123 # タスク参照（オプション、将来拡張）
task_type: commander # "commander" | "squad"
created_at: 2024-01-01T12:00:00
---
```

### Buffer-local Variables

```lua
vim.b[bufnr].vibing_role = "commander" | "squad"
vim.b[bufnr].vibing_squad_name = "Alpha"        -- 実行時の分隊名
vim.b[bufnr].vibing_original_squad = "Alpha"    -- frontmatter上の分隊名
vim.b[bufnr].vibing_task_ref = "github:#123"    -- タスク参照（将来拡張）
```

### Squad Registry (Global State)

```lua
-- lua/vibing/domain/squad/registry.lua
local M = {}

-- 現在使用中の分隊名 → bufnr のマッピング
M._active_squads = {}

function M.register(squad_name, bufnr)
function M.unregister(bufnr)
function M.is_available(squad_name)
function M.get_next_available()
function M.get_all_active()

return M
```

### Squad Assignments (Future)

`.vibing/squad_assignments.json`:

```json
{
  "version": 1,
  "assignments": {
    "github:#123": {
      "squad_name": "Alpha",
      "assigned_at": "2024-01-01T12:00:00"
    },
    "github:#124": {
      "squad_name": "Bravo",
      "assigned_at": "2024-01-02T10:00:00"
    }
  }
}
```

## Message Flow

### メンション返信フロー

```
1. Commander が @Alpha をメンション
   ↓
2. メンション集中管理システムが検知（後続Issue）
   ↓
3. Alpha 分隊に通知
   ↓
4. Alpha が処理を実行
   ↓
5. Alpha が Commander バッファに返信を書き込み
   - ヘッダー: ## Assistant <Alpha> <!-- unsent -->
   - 送信後:   ## Assistant <Alpha> <!-- {datetime} -->
```

### 具体例

**Commander バッファの変遷:**

```markdown
## User <!-- 2025-01-15 10:30:00 -->

Issue #123 を Alpha に割り当てて

## Assistant <Commander>

Issue #123 を Alpha 分隊に割り当てました。
@Alpha Issue #123 のログ機能実装をお願いします。

## Assistant <Alpha> ← Alpha がメンション返信として書き込み

了解しました。ログ機能を実装します...
```

## Implementation Phases

### Phase 1: 基盤（この Issue #305 のスコープ）

- [ ] NATO分隊名定数の定義 (`lua/vibing/domain/squad/constants.lua`)
- [ ] Squad Registry の実装 (`lua/vibing/domain/squad/registry.lua`)
- [ ] Commander/Squad 判定ロジック (`lua/vibing/domain/squad/role.lua`)
- [ ] frontmatter への squad_name/task_type 追加
- [ ] 新規チャット時の分隊名自動割り当て
- [ ] 既存チャット再開時の衝突処理
- [ ] 衝突時のバッファ内通知
- [ ] ヘッダー形式の拡張（`## Assistant <{name}>` 対応）
- [ ] timestamp.lua の拡張（squad名対応）

### Phase 2: Issue連携（別Issue）

- [ ] squad_assignments.json の読み書き
- [ ] GitHub Issue との紐付け
- [ ] GitLab/ローカル Issue サポート
- [ ] タスク参照フォーマット（`github:#123`, `gitlab:#456`, `local:task-id`）

### Phase 3: メンション機能（別Issue）

- [ ] `@Alpha` 形式のメンション解析
- [ ] メンション集中管理システム
- [ ] メンション先バッファへのメッセージ送信
- [ ] MCP tool: `nvim_reply_to_mention` の活用（`nvim_chat_send_message`は内部ツール）

## Task Reference Format (Future)

```
github:#123          # GitHub Issue
gitlab:#456          # GitLab Issue
local:my-task-id     # ローカル管理のタスク（TODO.md等）
jira:PROJ-789        # Jira Issue（将来拡張）
```

## Notes

- Commander は明示的に `<Commander>` として表示される
- Squad 名は NATO phonetic alphabet から自動割り当て
- メンション機能は後続Issueで実装
- Issue連携は後続Issueで実装
- MCP tool `nvim_reply_to_mention` を使ってメンション返信を実装（`nvim_chat_send_message`は内部ツールとして保持）
