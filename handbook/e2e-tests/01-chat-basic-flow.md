# E2Eテストケース: チャット基本フロー

## テストID

`E2E-CHAT-001`

## テスト対象

`:VibingChat` コマンドによる基本的なチャットセッションの作成と操作

## 前提条件

- Neovimがインストールされている
- vibing.nvimプラグインが正しくインストールされている
- Claude Agent SDKが正しく設定されている
- インターネット接続がある

## テスト手順

### 1. 新規チャットセッションの作成

**操作:**

```vim
:VibingChat
```

**期待される動作:**

- 新しいチャットバッファが作成される
- バッファ名は `vibing://chat-[timestamp]-[id]` 形式
- `filetype` が `vibing` に設定される
- バッファが `nomodifiable` に設定される
- ウィンドウが現在のウィンドウに表示される（デフォルト）

**検証ポイント:**

```lua
-- バッファが存在することを確認
assert(vim.api.nvim_buf_is_valid(bufnr))

-- fileTypeを確認
assert(vim.bo[bufnr].filetype == "vibing")

-- バッファ名を確認
local bufname = vim.api.nvim_buf_get_name(bufnr)
assert(bufname:match("^vibing://chat%-"))
```

### 2. チャットバッファの初期状態確認

**期待される内容:**

```markdown
---
created_at: [ISO8601 timestamp]
updated_at: [ISO8601 timestamp]
---

# Chat

<!-- Context: -->

<!-- Conversation: -->
```

**検証ポイント:**

- YAMLフロントマターが正しく設定されている
- `session_id` がまだ設定されていない（初回メッセージ前）
- `created_at` と `updated_at` がISO8601形式
- コンテキストセクションが空
- 会話セクションが空

### 3. 初回メッセージの送信

**操作:**

```
i
こんにちは
<CR>
```

**期待される動作:**

1. メッセージが送信される
2. ストリーミングレスポンスが表示される
3. `session_id` がフロントマターに追加される
4. `updated_at` が更新される

**検証ポイント:**

```markdown
---
created_at: [timestamp1]
updated_at: [timestamp2]
session_id: [UUID]
---

# Chat

<!-- Context: -->

<!-- Conversation: -->

## User

こんにちは

## Assistant

[Claude's response]
```

### 4. 継続的な会話

**操作:**

```
i
Neovimについて教えてください
<CR>
```

**期待される動作:**

- 同じ `session_id` で会話が継続される
- 新しいメッセージが会話履歴に追加される
- ストリーミングレスポンスが表示される

**検証ポイント:**

- `session_id` が変わっていない
- `updated_at` が更新されている
- 会話履歴が保持されている

### 5. チャットのキャンセル

**操作:**

```
i
長い質問を入力中...
<C-c>  # またはキャンセルキーマップ
```

**期待される動作:**

- メッセージ送信がキャンセルされる
- エラーメッセージが表示される（またはサイレントにキャンセル）
- バッファが破損しない

### 6. チャットの閉じる

**操作:**

```
:q
```

**期待される動作:**

- チャットバッファが閉じる
- チャット内容がファイルに保存される（`.vibing/chat/` ディレクトリ）
- Agent SDKプロセスが正しくクリーンアップされる

**検証ポイント:**

```bash
# チャットファイルが保存されていることを確認
ls -la .vibing/chat/
# chat-[timestamp]-[id].vibing ファイルが存在する
```

## 異常系テスト

### 7. Agent SDKが起動しない場合

**前提条件:**

- `bin/agent-wrapper.js` が存在しない

**期待される動作:**

- エラーメッセージが表示される
- チャットバッファは作成されるがメッセージ送信ができない

### 8. インターネット接続がない場合

**期待される動作:**

- タイムアウトエラーが表示される
- セッションが破損しない

### 9. 無効なAPIキー

**期待される動作:**

- 認証エラーが表示される
- エラーメッセージがチャットバッファに表示される

## パフォーマンステスト

### 10. 長文レスポンスのストリーミング

**操作:**

```
i
1000行のコードを生成してください
<CR>
```

**期待される動作:**

- UIがフリーズしない
- 50msごとにチャンクがフラッシュされる
- メモリリークがない

**検証ポイント:**

```lua
-- ストリーミング中もNeovimが応答する
-- メモリ使用量が異常に増加しない
```

## クリーンアップ

**操作:**

```bash
# テスト後にチャットファイルを削除
rm -rf .vibing/chat/chat-*.vibing
```

## 成功基準

- [ ] 新規チャットセッションが作成できる
- [ ] メッセージ送信とストリーミングレスポンスが正しく動作する
- [ ] セッションIDが正しく管理される
- [ ] 会話履歴が保持される
- [ ] チャットのキャンセルが正しく動作する
- [ ] チャットの保存と閉じるが正しく動作する
- [ ] エラーハンドリングが適切に機能する
- [ ] パフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/controller.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/buffer.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/use_case.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/send_message.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/adapter/agent_sdk.lua`
