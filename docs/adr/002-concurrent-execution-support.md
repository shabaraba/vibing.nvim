# ADR 002: Concurrent Execution Support

## Status

Accepted

## Context

vibing.nvimでは、ユーザーが複数のチャットウィンドウやインラインアクションを同時に実行するユースケースが増えてきました。従来の実装では以下の問題がありました：

1. **シングルトンアダプター問題**: グローバルに1つのアダプターインスタンスのみが存在し、複数の同時リクエストが干渉し合う
2. **セッション管理の不足**: セッションIDがリクエスト間で適切に管理されず、会話の継続性が失われる
3. **キューイングの欠如**: インラインアクションが同時に実行されると、ファイル競合が発生する可能性がある

## Decision

以下の設計変更を実装しました：

### 1. ハンドルベースの並行実行管理

**実装**: `agent_sdk.lua`

- 各`stream()`呼び出しで一意なハンドルIDを生成
- ハンドルIDはハイレゾタイマー + ランダム値で生成
- `_handles`と`_sessions`テーブルでハンドルごとに状態を管理

```lua
local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))
self._handles[handle_id] = vim.system(...)
self._sessions[handle_id] = session_id
```

### 2. セッションライフサイクル管理

**実装**: `agent_sdk.lua` + `chat.lua`

- セッションIDはハンドルIDにマッピングして保存
- ストリーミング完了時にハンドルは削除するが、セッションは保持
- `cleanup_stale_sessions()`で完了済みセッションを定期的にクリーンアップ

```lua
-- メッセージ送信前にクリーンアップ
adapter:cleanup_stale_sessions()

-- ストリーミング完了後はセッションを保持
-- NOTE: cleanup_session()はここで呼ばない
```

### 3. インラインアクションのキューイング

**実装**: `inline.lua`

- タスクキューで直列実行を保証
- `pcall`でエラーハンドリングを強化
- エラー時もキューが進むように設計

```lua
local on_complete = function()
  queue.is_executing = false
  process_queue()
end

local success, err = pcall(task.execute_fn, on_complete)
if not success then
  notify.error("An error occurred...", "Inline")
  on_complete()  -- エラー時も必ず呼ぶ
end
```

## Consequences

### Positive

1. **並行実行のサポート**: 複数のチャットウィンドウとインラインアクションが同時に動作
2. **セッション継続性**: チャット会話が適切に継続される
3. **エラー耐性**: キューがエラーでブロックされることがない
4. **メモリ管理**: 完了済みセッションは自動的にクリーンアップ

### Negative

1. **複雑性の増加**: ハンドルIDとセッションIDの2層管理が必要
2. **メモリ使用量**: 複数のハンドルとセッションを同時に保持
3. **デバッグの困難さ**: 並行実行のバグは再現が難しい

### Neutral

1. **後方互換性**: 既存のシングルチャット使用には影響なし
2. **パフォーマンス**: 並行実行により全体的なスループットは向上

## Implementation Notes

### テストカバレッジ

`tests/agent_sdk_spec.lua`に以下のテストを追加：

- `cleanup_stale_sessions`: 完了済みセッションのクリーンアップ
- `concurrent requests`: 複数セッションの同時管理
- `cleanup specific handle`: 個別ハンドルのクリーンアップ

### エラーハンドリング

- インラインキュー: ユーザーフレンドリーなエラーメッセージ
- アダプター: `on_done`は常に呼ばれることを保証

### メモリ管理

- `cleanup_stale_sessions()`をメッセージ送信前に呼び出し
- `__default__`キーは保持（後方互換性）
- 実行中のハンドルに紐づくセッションは保持

## References

- PR #239: Agent singleton check
- Review feedback: Session ID cleanup timing
- Review feedback: Queue error handling
- Review feedback: Handle ID generation

## Date

2024-12-29
