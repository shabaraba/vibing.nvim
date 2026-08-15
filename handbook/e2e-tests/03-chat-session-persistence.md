# E2Eテストケース: チャットセッション永続化

## テストID

`E2E-CHAT-003`

## テスト対象

チャットセッションの保存、読み込み、継続機能

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- `.vibing/chat/` ディレクトリが作成されている（または自動作成される）

## テスト手順

### 1. 新規チャットの自動保存

**操作:**

```vim
:VibingChat
i
テストメッセージ
<CR>
# レスポンスを待つ
:w
:q
```

**期待される動作:**

- チャットファイルが `.vibing/chat/` ディレクトリに保存される
- ファイル名が `chat-[timestamp]-[8桁のID].vibing` 形式
- ファイルにはYAMLフロントマターと会話内容が含まれる

**検証ポイント:**

```bash
# チャットファイルの存在確認
ls -la .vibing/chat/
# 最新のチャットファイルを確認
cat .vibing/chat/chat-*.vibing

# 期待される内容:
# ---
# created_at: [timestamp]
# updated_at: [timestamp]
# session_id: [UUID]
# ---
# # Chat
# ...
```

### 2. 保存されたチャットの再開

**操作:**

```vim
# 前のステップで保存されたチャットファイルを開く
:VibingChat .vibing/chat/chat-[timestamp]-[id].vibing
i
前回の続きです
<CR>
```

**期待される動作:**

- 保存されたチャット内容が表示される
- `session_id` が保持されている
- 新しいメッセージが同じセッションで送信される
- 会話履歴が継続される

**検証ポイント:**

```lua
-- フロントマターからsession_idを取得
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local session_id_line = nil
for _, line in ipairs(lines) do
  if line:match("^session_id:") then
    session_id_line = line
    break
  end
end
assert(session_id_line ~= nil)
```

### 3. フロントマターの更新

**操作:**

```vim
:VibingChat
i
メッセージ1
<CR>
# レスポンスを待つ
i
メッセージ2
<CR>
# レスポンスを待つ
:w
```

**期待される動作:**

- `updated_at` が最新のタイムスタンプに更新される
- `created_at` は変更されない
- `session_id` は変更されない

**検証ポイント:**

```markdown
---
created_at: 2026-01-17T10:00:00.000Z # 変更なし
updated_at: 2026-01-17T10:05:00.000Z # 更新される
session_id: abc123-def456-... # 変更なし
---
```

### 4. セッション破損時の自動リセット

**前提条件:**

- 既存のチャットファイルに無効な `session_id` がある

**操作:**

```vim
# セッションIDを手動で破損させる
# ファイルを編集: session_id: invalid-session-id
:VibingChat .vibing/chat/chat-[timestamp]-[id].vibing
i
新しいメッセージ
<CR>
```

**期待される動作:**

- Agent SDKがセッションエラーを検出する
- `session_id` が自動的にリセットされる（`nil` または削除）
- 新しいセッションとして会話が開始される
- ユーザーに通知が表示される

**検証ポイント:**

```lua
-- エラーログに "Session corrupted" または類似のメッセージがある
-- フロントマターから session_id が削除されている
```

### 5. 複数チャットの同時管理

**操作:**

```vim
:VibingChat right
i
チャット1のメッセージ
<CR>
# レスポンスを待つ

:VibingChat left
i
チャット2のメッセージ
<CR>
# レスポンスを待つ

:wa  # 全バッファを保存
:qa  # 全バッファを閉じる
```

**期待される動作:**

- 2つの独立したチャットファイルが作成される
- それぞれ異なる `session_id` を持つ
- 両方のファイルが正しく保存される

**検証ポイント:**

```bash
ls -la .vibing/chat/
# 2つのchat-*.vibingファイルが存在する

# それぞれのファイルが異なるsession_idを持つことを確認
grep "session_id:" .vibing/chat/chat-*.vibing
```

### 6. 会話履歴の完全性

**操作:**

```vim
:VibingChat
i
メッセージ1
<CR>
i
メッセージ2
<CR>
i
メッセージ3
<CR>
:w
:q

# 再度開く
:VibingChat .vibing/chat/chat-[timestamp]-[id].vibing
```

**期待される動作:**

- 全ての会話履歴が正しい順序で表示される
- ユーザーメッセージとアシスタントレスポンスが交互に並ぶ
- タイムスタンプや書式が保持される

**検証ポイント:**

```markdown
<!-- Conversation: -->

## User

メッセージ1

## Assistant

[レスポンス1]

## User

メッセージ2

## Assistant

[レスポンス2]

## User

メッセージ3

## Assistant

[レスポンス3]
```

### 7. バッファ変更の自動保存

**操作:**

```vim
:VibingChat
i
テストメッセージ
<CR>
# レスポンスを待つ
:q  # :w せずに閉じる
```

**期待される動作:**

- `BufDelete` autocmdが発火する
- チャット内容が自動的に保存される
- ユーザーに保存確認は求められない（vibingバッファは自動保存）

**検証ポイント:**

```bash
# チャットファイルが存在することを確認
ls -la .vibing/chat/chat-*.vibing
```

## 異常系テスト

### 8. ファイルシステムエラー

**前提条件:**

- `.vibing/chat/` ディレクトリに書き込み権限がない

**操作:**

```vim
:VibingChat
i
テストメッセージ
<CR>
:w
```

**期待される動作:**

- エラーメッセージが表示される
- Neovimがクラッシュしない
- バッファ内容は保持される

### 9. 無効なフロントマター

**前提条件:**

- チャットファイルのYAMLフロントマターが壊れている

**操作:**

```vim
:VibingChat .vibing/chat/broken-chat.vibing
```

**期待される動作:**

- エラーメッセージが表示される、またはフロントマターを無視して開く
- Neovimがクラッシュしない

### 10. 大量の会話履歴

**操作:**

```vim
# 100回のメッセージ交換をシミュレート
:VibingChat
# スクリプトで100回繰り返す
for i in range(100):
  i
  メッセージ${i}
  <CR>
  # レスポンスを待つ
:w
```

**期待される動作:**

- ファイルサイズが大きくなっても正しく保存される
- 読み込み時のパフォーマンスが許容範囲内
- メモリリークがない

**検証ポイント:**

```bash
# ファイルサイズを確認
ls -lh .vibing/chat/chat-*.vibing
# 読み込み時間を測定
time nvim -c ":VibingChat .vibing/chat/chat-*.vibing" -c ":q"
```

## クリーンアップ

**操作:**

```bash
# テスト後にチャットファイルを削除
rm -rf .vibing/chat/chat-*.vibing
```

## 成功基準

- [ ] チャットが正しく保存される
- [ ] 保存されたチャットが正しく再開できる
- [ ] フロントマターが正しく管理される
- [ ] セッション破損時の自動リセットが機能する
- [ ] 複数チャットの同時管理ができる
- [ ] 会話履歴の完全性が保たれる
- [ ] 自動保存が正しく動作する
- [ ] エラーハンドリングが適切に機能する
- [ ] 大量の会話履歴でもパフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/domain/chat/session.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/frontmatter_handler.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/conversation_extractor.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/use_case.lua`
