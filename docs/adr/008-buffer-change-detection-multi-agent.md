# ADR 008: Buffer Change Detection for Multi-Agent Coordination

## Status

Accepted - Phase 3+ Complete

**Implementation Status:**
- ✅ Phase 1: Core Components (PoC) - Complete
- ✅ Phase 2: ChatBuffer Integration - Complete
- ✅ Phase 2.5: canToolUse-based Mention Interruption - Complete
- ✅ Phase 3: State Persistence - Complete (shared_buffer_enabled persists in frontmatter)
- ✅ Phase 3+: Enhanced UX - Complete (:VibingMention, highlighting, auto-completion, session picker)
- 🚧 Future: Auto-response capabilities, multiple buffers - Pending

## Date

2026-01-11 (Created)
2026-01-12 (Updated - Phase 3+ Complete)

## Context

vibing.nvim は現在、複数のチャットセッションを同時に実行できますが（ADR 002）、各セッションは独立して動作し、他のセッションとのコミュニケーション手段がありません。

### 要求されている機能

1. **複数 Claude 間の協調作業**: 一方の Claude が他方の Claude のバッファに書き込み、それを検知して内容を確認する
2. **共有雑談バッファ**: 各 Claude が自由に進捗や状況を書き込み、他の Claude がそれを検知して必要に応じて返答する
3. **メンション機能**: `@Claude-1` のように特定の Claude を呼び出す、または `@All` で全 Claude に通知
4. **非同期通知**: バッファへの書き込みをリアルタイムで検知し、該当する Claude セッションに通知

### ユースケース

**ケース 1: コードレビューの協調**

```markdown
## 2026-01-11 18:00:00 Claude-1

@Claude-2 ログイン機能の実装が完了しました。レビューお願いします。
ファイル: src/auth/login.ts

## 2026-01-11 18:05:00 Claude-2

@Claude-1 確認しました。セキュリティ面で気になる点があります。
```

**ケース 2: 進捗共有**

```markdown
## 2026-01-11 18:00:00 Claude-1

[進捗] バックエンド API の実装完了

## 2026-01-11 18:05:00 Claude-2

[進捗] フロントエンドのコンポーネント実装中

## 2026-01-11 18:10:00 Claude-3

@All 全体的な進捗を確認したいです。ステータスを教えてください。
```

### 技術的課題

1. **バッファ変更の検知**: Neovim でバッファへの変更をリアルタイムで検知する必要がある
2. **メッセージパース**: メンションや Claude ID を正確に抽出する
3. **通知の配送**: 該当する Claude セッションに確実に通知を届ける
4. **競合回避**: 複数の Claude が同時に書き込む際の競合を防ぐ
5. **無限ループ防止**: Claude が互いに反応し合って無限ループに陥るのを防ぐ

## Decision

**nvim_buf_attach API を使用したリアルタイムバッファ変更検知システムと、共有バッファベースのマルチエージェント協調機能**を実装します。

### アーキテクチャ

```
┌─────────────────────────────────────────────────────────────┐
│ Neovim Process                                               │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Shared Buffer (.vibing-shared)                       │    │
│  │  - nvim_buf_attach() で変更監視                      │    │
│  │  - on_lines コールバックで変更を検知                │    │
│  └─────────────────────────────────────────────────────┘    │
│                    ↓ 変更イベント                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Change Notification System                           │    │
│  │  - メッセージパース（## Claude-1, @Claude-2 など） │    │
│  │  - メンション抽出（@Claude-{id}, @All）            │    │
│  │  - 該当セッションの特定                             │    │
│  └─────────────────────────────────────────────────────┘    │
│           ↓ 通知配送                   ↓ 通知配送             │
│  ┌────────────────────┐      ┌────────────────────┐         │
│  │ Claude Session 1   │      │ Claude Session 2   │         │
│  │  - session_id      │      │  - session_id      │         │
│  │  - claude_id       │      │  - claude_id       │         │
│  │  - 通知ハンドラ     │      │  - 通知ハンドラ     │         │
│  └────────────────────┘      └────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

### コンポーネント設計

#### 1. Buffer Change Watcher

**ファイル**: `lua/vibing/core/buffer_watcher.lua`

```lua
local M = {}

---@class BufferWatcherCallback
---@field on_change fun(bufnr: number, changed_tick: number, firstline: number, lastline: number, new_lastline: number, lines: string[]): nil

---@type table<number, BufferWatcherCallback[]>
local watchers = {}

---バッファの変更監視を開始
---@param bufnr number
---@param callback BufferWatcherCallback
---@return boolean success
function M.attach(bufnr, callback)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- nvim_buf_attach で変更を監視
  local ok = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, changedtick, firstline, lastline, new_lastline)
      local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
      callback.on_change(buf, changedtick, firstline, lastline, new_lastline, lines)
    end,
  })

  if ok then
    watchers[bufnr] = watchers[bufnr] or {}
    table.insert(watchers[bufnr], callback)
  end

  return ok
end

---バッファの監視を解除
---@param bufnr number
function M.detach(bufnr)
  watchers[bufnr] = nil
  -- nvim_buf_detach は Neovim API に存在しないため、
  -- nvim_buf_attach の戻り値 (detach function) を保存する必要がある
end

return M
```

#### 2. Shared Buffer Manager

**ファイル**: `lua/vibing/application/shared_buffer/manager.lua`

```lua
local BufferWatcher = require("vibing.core.buffer_watcher")
local MessageParser = require("vibing.application.shared_buffer.message_parser")
local NotificationDispatcher = require("vibing.application.shared_buffer.notification_dispatcher")

local M = {}

---@type number? 共有バッファの番号
local shared_bufnr = nil

---共有バッファを作成または取得
---@return number bufnr
function M.get_or_create_shared_buffer()
  if shared_bufnr and vim.api.nvim_buf_is_valid(shared_bufnr) then
    return shared_bufnr
  end

  -- 既存の .vibing-shared バッファを検索
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.vibing%-shared$") then
      shared_bufnr = buf
      M._setup_watcher(shared_bufnr)
      return shared_bufnr
    end
  end

  -- 新規作成
  shared_bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[shared_bufnr].buftype = ""
  vim.bo[shared_bufnr].filetype = "vibing-shared"
  vim.bo[shared_bufnr].syntax = "markdown"

  local save_dir = vim.fn.stdpath("data") .. "/vibing/shared/"
  vim.fn.mkdir(save_dir, "p")
  local filename = "shared-" .. os.date("%Y%m%d") .. ".vibing-shared"
  vim.api.nvim_buf_set_name(shared_bufnr, save_dir .. filename)

  -- 初期コンテンツ
  local lines = {
    "---",
    "vibing.nvim: true",
    "type: shared",
    "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"),
    "---",
    "",
    "# Shared Buffer",
    "",
    "This buffer is shared among multiple Claude sessions.",
    "Use `@Claude-{id}` to mention a specific session or `@All` for everyone.",
    "",
  }
  vim.api.nvim_buf_set_lines(shared_bufnr, 0, -1, false, lines)

  M._setup_watcher(shared_bufnr)

  return shared_bufnr
end

---バッファ変更の監視を設定
---@param bufnr number
function M._setup_watcher(bufnr)
  BufferWatcher.attach(bufnr, {
    on_change = function(buf, changedtick, firstline, lastline, new_lastline, lines)
      -- 変更された行を解析
      local messages = MessageParser.parse_lines(lines)

      -- メンションを抽出して通知を配送
      for _, msg in ipairs(messages) do
        NotificationDispatcher.dispatch(msg)
      end
    end,
  })
end

---共有バッファを開く
---@param position? "current"|"right"|"left"
function M.open_shared_buffer(position)
  position = position or "right"

  local bufnr = M.get_or_create_shared_buffer()

  if position == "current" then
    vim.api.nvim_set_current_buf(bufnr)
  elseif position == "right" then
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(bufnr)
  elseif position == "left" then
    vim.cmd("vsplit")
    vim.cmd("wincmd H")
    vim.api.nvim_set_current_buf(bufnr)
  end
end

return M
```

#### 3. Message Parser

**ファイル**: `lua/vibing/application/shared_buffer/message_parser.lua`

```lua
local M = {}

---@class SharedMessage
---@field timestamp string
---@field from_claude_id string
---@field mentions string[] メンションされた Claude ID のリスト (@Claude-1, @All など)
---@field content string

---行をパースしてメッセージ構造を抽出
---@param lines string[]
---@return SharedMessage[]
function M.parse_lines(lines)
  local messages = {}

  for _, line in ipairs(lines) do
    -- ヘッダーフォーマット: ## 2026-01-11 18:00:00 Claude-1
    local timestamp, claude_id = line:match("^## (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) Claude%-(%w+)")

    if timestamp and claude_id then
      -- メンションを抽出: @Claude-1, @Claude-2, @All
      local mentions = {}
      for mention in line:gmatch("@(Claude%-%w+)") do
        table.insert(mentions, mention)
      end
      for mention in line:gmatch("@(All)") do
        table.insert(mentions, mention)
      end

      table.insert(messages, {
        timestamp = timestamp,
        from_claude_id = claude_id,
        mentions = mentions,
        content = line,
      })
    end
  end

  return messages
end

return M
```

#### 4. Notification Dispatcher

**ファイル**: `lua/vibing/application/shared_buffer/notification_dispatcher.lua`

```lua
local M = {}

---@type table<string, {session_id: string, bufnr: number, on_notification: function}>
local registered_sessions = {}

---Claude セッションを登録
---@param claude_id string
---@param session_id string
---@param bufnr number
---@param on_notification function
function M.register_session(claude_id, session_id, bufnr, on_notification)
  registered_sessions[claude_id] = {
    session_id = session_id,
    bufnr = bufnr,
    on_notification = on_notification,
  }
end

---セッションの登録を解除
---@param claude_id string
function M.unregister_session(claude_id)
  registered_sessions[claude_id] = nil
end

---通知を配送
---@param message SharedMessage
function M.dispatch(message)
  -- @All の場合は全セッションに通知
  if vim.tbl_contains(message.mentions, "All") then
    for claude_id, session in pairs(registered_sessions) do
      -- 自分自身には通知しない
      if claude_id ~= message.from_claude_id then
        session.on_notification(message)
      end
    end
    return
  end

  -- 特定の Claude へのメンションを処理
  for _, mention in ipairs(message.mentions) do
    local session = registered_sessions[mention]
    if session then
      session.on_notification(message)
    end
  end
end

return M
```

#### 5. Claude Session Integration

**ファイル**: `lua/vibing/presentation/chat/buffer.lua` (既存ファイルへの追加)

```lua
-- ChatBuffer クラスに以下を追加:

---Claude ID を生成（session_id の短縮版）
---@return string
function ChatBuffer:_generate_claude_id()
  if not self.session_id then
    return "unknown"
  end
  -- session_id の最初の5文字を使用
  return self.session_id:sub(1, 5)
end

---共有バッファからの通知を受信
---@param message SharedMessage
function ChatBuffer:_on_shared_buffer_notification(message)
  -- 通知をバッファに表示
  vim.notify(
    string.format("[Claude-%s] %s", message.from_claude_id, message.content),
    vim.log.levels.INFO
  )

  -- オプション: 自動的に共有バッファを開く
  -- local SharedBufferManager = require("vibing.application.shared_buffer.manager")
  -- SharedBufferManager.open_shared_buffer("right")
end

---セッションを共有バッファシステムに登録
function ChatBuffer:_register_to_shared_buffer()
  if not self.session_id then
    return
  end

  local claude_id = "Claude-" .. self:_generate_claude_id()
  local NotificationDispatcher = require("vibing.application.shared_buffer.notification_dispatcher")

  NotificationDispatcher.register_session(
    claude_id,
    self.session_id,
    self.buf,
    function(message)
      self:_on_shared_buffer_notification(message)
    end
  )
end
```

### メッセージフォーマット

共有バッファでは以下のフォーマットを使用します：

```markdown
---
vibing.nvim: true
type: shared
created_at: 2026-01-11T18:00:00
---

# Shared Buffer

## 2026-01-11 18:00:00 Claude-abc12

@Claude-def34 ログイン機能の実装が完了しました。レビューお願いします。

## 2026-01-11 18:05:00 Claude-def34

@Claude-abc12 確認しました。問題ありません。

## 2026-01-11 18:10:00 Claude-xyz56

@All 全体的な進捗を確認したいです。
```

**Key Points:**

- ヘッダーフォーマット: `## YYYY-MM-DD HH:MM:SS Claude-{id}`
- メンション: `@Claude-{id}` または `@All`
- Claude ID: session_id の最初の5文字（例: `abc12`）

## Consequences

### Positive

1. **マルチエージェント協調**: 複数の Claude セッションが協調してタスクを実行できる
2. **非同期コミュニケーション**: 各 Claude が非同期で情報を共有し、必要に応じて返答できる
3. **可視性**: 共有バッファで全ての Claude の活動を一目で確認できる
4. **柔軟性**: メンション機能により特定の Claude を呼び出すか、全体に通知するか選択できる
5. **既存機能との統合**: 現在の concurrent execution support (ADR 002) と自然に統合される

### Negative

1. **実装の複雑さ**: バッファ監視、メッセージパース、通知配送など複数のコンポーネントが必要
2. **パフォーマンスオーバーヘッド**: nvim_buf_attach によるリアルタイム監視は CPU リソースを消費する可能性
3. **デバッグの難しさ**: 複数のセッションが相互作用するため、問題の原因特定が困難になる可能性
4. **メモリ消費**: 複数のセッションが同時に動作する場合、メモリ使用量が増加
5. **UI の複雑化**: 共有バッファと個別チャットバッファの管理がユーザーにとって複雑になる可能性

### Risks and Mitigations

**Risk 1: 無限ループ**

- **問題**: Claude が互いに反応し合って無限ループに陥る
- **緩和策**:
  - メッセージに「返信回数」カウンターを含める
  - 短時間での連続メッセージを検出してアラートを出す
  - ユーザーが手動で介入できる仕組みを提供

**Risk 2: 競合状態**

- **問題**: 複数の Claude が同時に共有バッファに書き込むと競合が発生
- **緩和策**:
  - 書き込み時に vim.schedule() を使用してメインループに委譲
  - 短時間のロック機構を実装（Lua の coroutine ベース）

**Risk 3: 通知の見逃し**

- **問題**: Claude が通知を受け取っても気づかない、または対応しない
- **緩和策**:
  - 通知履歴を保存し、後から確認できるようにする
  - ハイライト表示やサウンド通知を追加（オプション）

**Risk 4: セッション管理の複雑化**

- **問題**: 多数のセッションが登録されると管理が困難
- **緩和策**:
  - セッション一覧表示コマンドを提供 (`:VibingListSessions`)
  - 非アクティブなセッションの自動クリーンアップ

## Alternatives Considered

### Alternative 1: WebSocket ベースの通信

**概要**: MCP サーバーに WebSocket を追加し、セッション間通信を実現

**却下理由**:

- 追加の依存関係（WebSocket ライブラリ）が必要
- MCP サーバーの複雑化
- Neovim プロセス外部との通信が発生し、セキュリティリスク増加
- オーバーエンジニアリング

### Alternative 2: ファイルベースの監視

**概要**: 共有ファイルを監視し、変更を検出

**却下理由**:

- ファイル I/O のオーバーヘッドが大きい
- ファイルシステムの監視機能（inotify など）が環境依存
- Neovim バッファとの同期が複雑
- リアルタイム性が低い

### Alternative 3: autocommand (TextChanged) ベース

**概要**: TextChanged イベントを使用してバッファ変更を検知

**却下理由**:

- nvim_buf_attach より粒度が粗い（行単位での変更情報が取れない）
- イベントの発火頻度が不安定
- ユーザーが手動で編集した場合にも発火するため、フィルタリングが必要

### Alternative 4: 外部ツール統合（tmux, screen）

**概要**: tmux のペイン間通信機能を使用

**却下理由**:

- 環境依存（tmux がインストールされていない環境では動作しない）
- Neovim プラグインとしての移植性が低下
- ユーザーが tmux を使用していない場合は利用不可

## Implementation Notes

### Phase 1: Core Components (PoC)

1. **Buffer Watcher** (`lua/vibing/core/buffer_watcher.lua`)
   - nvim_buf_attach の基本実装
   - on_lines コールバックのテスト

2. **Message Parser** (`lua/vibing/application/shared_buffer/message_parser.lua`)
   - ヘッダーフォーマットのパース
   - メンション抽出ロジック

3. **Notification Dispatcher** (`lua/vibing/application/shared_buffer/notification_dispatcher.lua`)
   - セッション登録・解除
   - 通知配送ロジック

### Phase 2: Shared Buffer Management

4. **Shared Buffer Manager** (`lua/vibing/application/shared_buffer/manager.lua`)
   - 共有バッファの作成・管理
   - バッファ監視の設定

5. **ChatBuffer Integration** (`lua/vibing/presentation/chat/buffer.lua`)
   - Claude ID 生成
   - 通知受信ハンドラ
   - セッション登録

### Phase 3: User Commands & UI

6. **User Commands**
   - `:VibingShared [position]` - 共有バッファを開く
   - `:VibingListSessions` - アクティブなセッション一覧を表示
   - `:VibingMention <claude-id>` - 特定の Claude にメンション

7. **UI Enhancements**
   - 通知のハイライト表示
   - メンションの自動補完
   - セッション一覧ピッカー

### Phase 4: Safety & Polish

8. **Safety Mechanisms**
   - 無限ループ検出
   - 競合状態の緩和
   - エラーハンドリング

9. **Documentation**
   - ユーザーガイド
   - API ドキュメント
   - 使用例

### Testing Strategy

**ユニットテスト:**

- MessageParser のパースロジック
- NotificationDispatcher の配送ロジック

**統合テスト:**

- 複数セッションの起動と通信
- メンション機能の動作確認
- 共有バッファの変更検知

**E2E テスト（手動）:**

- 実際の Claude セッションでの協調作業
- パフォーマンステスト（多数のセッション）

## References

- [ADR 002: Concurrent Execution Support](./002-concurrent-execution-support.md)
- [ADR 004: Multi-Instance Neovim Support](./004-multi-instance-neovim-support.md)
- Neovim `:help nvim_buf_attach()`
- Neovim `:help vim.schedule()`
- [MCP Integration Documentation](../../CLAUDE.md#mcp-integration-model-context-protocol)

## Notes

この機能は experimental な位置づけで開始します。ユーザーフィードバックを元に改善を重ね、安定してから default で有効化することを検討します。

初期実装では以下の制限があります:

- 共有バッファは1つのみ（複数の共有バッファはサポートしない）
- メンションは基本的な `@Claude-{id}` と `@All` のみ
- 通知は vim.notify() による表示のみ（自動返答機能は含まない）

将来的には以下の拡張を検討します:

- 複数の共有バッファ（プロジェクトごと、トピックごと）
- リッチなメンション機能（役割ベース、優先度指定）
- AI による自動返答判断（メンションされたら自動的に返答するかどうかを AI が判断）
- 共有バッファの履歴検索・フィルタリング
