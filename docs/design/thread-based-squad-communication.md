# Thread-Based Squad Communication Design

## Overview

Squad間の相談機能を「スレッド方式」で再設計する。
作業バッファを汚さず、明確なライフサイクルを持つ一時バッファで議論を行う。

## Current Problems

1. **引数の複雑さ**: `thread_bufnr`, `from_bufnr`, `to_bufnr` の3つが必要で、Claudeが間違えやすい
2. **ライフサイクル不明確**: スレッドの開始・終了が曖昧、放置されると終わらない
3. **作業バッファの汚染**: 作業ログと相談メッセージが混在

## Design Goals

- シンプルなAPI（引数を減らす）
- 明確なライフサイクル（作成→やり取り→終了→要約）
- 作業バッファはクリーンに保つ（通知のみ）
- タイムアウトによる自動終了

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Thread Lifecycle                                                     │
│                                                                       │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐       │
│   │ CREATE  │ ──► │ MESSAGE │ ──► │  CLOSE  │ ──► │ SUMMARY │       │
│   └─────────┘     └─────────┘     └─────────┘     └─────────┘       │
│       │               │               │               │              │
│       │               │               │               ▼              │
│       │               │               │         Owner's Buffer       │
│       │               │               │         (summary追記)        │
│       │               │               ▼                              │
│       │               │         Thread Buffer                        │
│       │               │           削除                               │
│       │               ▼                                              │
│       │         Thread Buffer                                        │
│       │         (messages append)                                    │
│       ▼                                                              │
│  Thread Buffer 作成                                                  │
│  + 参加者に通知                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## MCP Tools

### 1. `nvim_thread_create`

スレッドを作成し、参加者に通知する。

```typescript
{
  name: 'nvim_thread_create',
  description: 'Create a discussion thread with specified participants. Returns thread_id for subsequent operations.',
  inputSchema: {
    type: 'object',
    properties: {
      topic: {
        type: 'string',
        description: 'Topic/purpose of the discussion',
      },
      participants: {
        type: 'array',
        items: { type: 'string' },
        description: 'Squad names to invite (e.g., ["Alpha", "Beta"])',
      },
      rpc_port: {
        type: 'number',
        description: 'RPC port',
      },
    },
    required: ['topic', 'participants'],
  },
}
```

**Response:**

```json
{
  "thread_id": "thread_abc123",
  "thread_bufnr": 42,
  "owner_squad": "Commander",
  "participants": ["Alpha", "Beta"],
  "created_at": "2025-01-17T10:00:00Z"
}
```

### 2. `nvim_thread_message`

スレッドにメッセージを送信する。**引数をシンプル化**。

```typescript
{
  name: 'nvim_thread_message',
  description: 'Send a message to a thread. The thread_id identifies where to write.',
  inputSchema: {
    type: 'object',
    properties: {
      thread_id: {
        type: 'string',
        description: 'Thread ID from nvim_thread_create or notification',
      },
      message: {
        type: 'string',
        description: 'Your message content',
      },
      rpc_port: {
        type: 'number',
        description: 'RPC port',
      },
    },
    required: ['thread_id', 'message'],
  },
}
```

**Key Simplification:**

- `from_bufnr` は不要 → `VIBING_SQUAD_BUFNR` 環境変数から取得
- `to_bufnr` は不要 → スレッド内の他参加者全員に通知
- `thread_bufnr` は不要 → `thread_id` からLua側で解決

### 3. `nvim_thread_close`

スレッドを終了し、オプションで要約を生成する。

```typescript
{
  name: 'nvim_thread_close',
  description: 'Close a thread. Only the thread owner can close it. Optionally generates a summary.',
  inputSchema: {
    type: 'object',
    properties: {
      thread_id: {
        type: 'string',
        description: 'Thread ID to close',
      },
      generate_summary: {
        type: 'boolean',
        description: 'Whether to generate and append summary to owner buffer (default: true)',
        default: true,
      },
      rpc_port: {
        type: 'number',
        description: 'RPC port',
      },
    },
    required: ['thread_id'],
  },
}
```

### 4. `nvim_thread_list`

アクティブなスレッド一覧を取得する。

```typescript
{
  name: 'nvim_thread_list',
  description: 'List active threads you are participating in.',
  inputSchema: {
    type: 'object',
    properties: {
      rpc_port: {
        type: 'number',
        description: 'RPC port',
      },
    },
  },
}
```

## Lua Modules

### 1. `infrastructure/thread/registry.lua`

スレッドのインメモリ管理。

```lua
---@class Vibing.Infrastructure.Thread.Registry
local M = {}

---@class ThreadEntry
---@field thread_id string
---@field thread_bufnr number
---@field owner_bufnr number
---@field owner_squad string
---@field topic string
---@field participants table<string, number> squad_name → bufnr
---@field created_at number timestamp
---@field last_activity_at number timestamp

-- Active threads: thread_id → ThreadEntry
M._threads = {}

-- Reverse lookup: bufnr → thread_id (for thread buffers)
M._bufnr_to_thread = {}

function M.create(owner_bufnr, topic, participant_bufnrs) → ThreadEntry
function M.get(thread_id) → ThreadEntry?
function M.get_by_bufnr(thread_bufnr) → ThreadEntry?
function M.update_activity(thread_id)
function M.close(thread_id) → boolean
function M.list_for_squad(squad_name) → ThreadEntry[]
function M.cleanup_stale() -- タイムアウト処理

return M
```

### 2. `infrastructure/thread/buffer.lua`

スレッドバッファの作成・管理。

```lua
---@class Vibing.Infrastructure.Thread.Buffer
local M = {}

function M.create(topic, owner_squad, participants) → bufnr
function M.append_message(bufnr, from_squad, message)
function M.get_content(bufnr) → string
function M.delete(bufnr)

return M
```

### 3. `application/thread/service.lua`

スレッド操作のアプリケーションサービス。

```lua
---@class Vibing.Application.Thread.Service
local M = {}

function M.create_thread(owner_bufnr, topic, participant_squad_names)
  -- 1. ThreadRegistry.create()
  -- 2. ThreadBuffer.create()
  -- 3. 参加者に通知（Notifier経由）
  -- 4. タイムアウトタイマー開始
end

function M.send_message(thread_id, from_bufnr, message)
  -- 1. スレッド存在確認
  -- 2. 参加者確認
  -- 3. ThreadBuffer.append_message()
  -- 4. 他参加者に通知（アイドルなら）
  -- 5. タイムアウトリセット
end

function M.close_thread(thread_id, from_bufnr, generate_summary)
  -- 1. オーナー確認
  -- 2. 要約生成（オプション）
  -- 3. オーナーバッファに要約追記
  -- 4. ThreadBuffer.delete()
  -- 5. ThreadRegistry.close()
end

function M.handle_timeout(thread_id)
  -- 自動終了処理
end

return M
```

### 4. `infrastructure/rpc/handlers/thread.lua`

RPCハンドラー。

```lua
---@class Vibing.Infrastructure.RPC.ThreadHandler
local M = {}

function M.thread_create(params)
function M.thread_message(params)
function M.thread_close(params)
function M.thread_list(params)

return M
```

## Thread Buffer Format

```markdown
---
vibing_thread: true
thread_id: thread_abc123
topic: 'エラーハンドリングの設計相談'
owner: Commander
participants:
  - Alpha
  - Beta
created_at: 2025-01-17T10:00:00
status: active
---

## @Commander (10:00:00)

エラーハンドリングについて相談したい。
現在の実装では try-catch を使っているが、
Result型パターンに移行すべきか検討中。

## @Alpha (10:02:15)

私の作業範囲では try-catch で問題なく動作しています。
ただ、ネストが深くなる傾向があるのは気になっています。

## @Beta (10:03:30)

Result型パターンは良いと思います。
TypeScriptでの実装例を調べてみましょうか？

## @Commander (10:05:00)

/close ありがとう。Result型パターンで進めることにします。
```

## Notification Format

### Thread Invitation (参加者のバッファに表示)

```markdown
📩 Thread invitation from @Commander
Topic: "エラーハンドリングの設計相談"
Thread ID: thread_abc123
Participants: Alpha, Beta

To reply, use: nvim_thread_message with thread_id="thread_abc123"
```

### Thread Closed (参加者のバッファに表示)

```markdown
📋 Thread closed: thread_abc123
Topic: "エラーハンドリングの設計相談"
Duration: 5分
Participants: Commander, Alpha, Beta
```

### Summary (オーナーのバッファに追記)

```markdown
## Thread Summary: エラーハンドリングの設計相談

**Participants:** Alpha, Beta
**Duration:** 5分
**Conclusion:**

- Result型パターンで進めることに決定
- Betaが実装例を調査予定
```

## Timeout Handling

- **デフォルトタイムアウト**: 5分（設定可能）
- **タイムアウト時の挙動**:
  1. 全参加者に「Thread timed out」通知
  2. 要約を生成してオーナーバッファに追記
  3. スレッドバッファを削除
  4. Registryから削除

```lua
-- タイムアウト設定
config.thread = {
  timeout_minutes = 5,
  auto_summary_on_timeout = true,
}
```

## Environment Variables

スレッドメッセージ送信時に `from_bufnr` を自動解決するため、
Agent起動時に以下の環境変数を設定：

```bash
VIBING_SQUAD_BUFNR=42  # このAgentのバッファ番号
```

これにより、`nvim_thread_message` は `thread_id` と `message` だけでOK。

## Migration Plan

### Phase 1: 新API追加（既存と並行）

1. `infrastructure/thread/` モジュール実装
2. `application/thread/service.lua` 実装
3. MCP tools: `nvim_thread_*` 追加
4. 既存の `nvim_squad_thread_message` は維持

### Phase 2: CLAUDE.md更新

1. 新APIの使用例をCLAUDE.mdに追加
2. 旧APIを「非推奨」としてマーク

### Phase 3: 旧API削除

1. 十分なテスト期間後に旧APIを削除
2. `nvim_squad_thread_message` を新 `nvim_thread_message` にリダイレクト（一時的）

## Open Questions

1. **要約生成の実装**: Claude APIを呼ぶ？ローカルで簡易要約？
   - 案: スレッド内容をユーザーメッセージとして送信し、要約を依頼

2. **スレッドの永続化**: ファイルに保存すべき？
   - 現時点では不要（インメモリのみ）
   - 将来的には `.vibing/threads/` に保存可能

3. **複数スレッド同時参加**: 1つのSquadが複数スレッドに参加できる？
   - → Yes、可能にする

4. **スレッドオーナーの離脱**: オーナーのバッファが閉じられた場合
   - → 自動的にスレッド終了（要約なし）
