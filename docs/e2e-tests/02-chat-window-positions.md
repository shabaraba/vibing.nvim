# E2Eテストケース: チャットウィンドウ配置

## テストID

`E2E-CHAT-002`

## テスト対象

`:VibingChat` コマンドの位置指定オプション

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている

## テスト手順

### 1. デフォルト位置（current）

**操作:**

```vim
:VibingChat
```

**期待される動作:**

- 現在のウィンドウにチャットバッファが表示される
- 元のバッファが置き換えられる

**検証ポイント:**

```lua
local current_win = vim.api.nvim_get_current_win()
local bufnr = vim.api.nvim_win_get_buf(current_win)
local bufname = vim.api.nvim_buf_get_name(bufnr)
assert(bufname:match("^vibing://chat%-"))
```

### 2. 右分割（right）

**操作:**

```vim
:VibingChat right
```

**期待される動作:**

- 現在のウィンドウの右側に新しいウィンドウが作成される
- チャットバッファが新しいウィンドウに表示される
- 元のウィンドウとバッファは保持される

**検証ポイント:**

```lua
-- ウィンドウ数が増加していることを確認
local before_count = #vim.api.nvim_list_wins()
-- :VibingChat right 実行
local after_count = #vim.api.nvim_list_wins()
assert(after_count == before_count + 1)

-- 新しいウィンドウが右側にあることを確認（位置の検証）
```

### 3. 左分割（left）

**操作:**

```vim
:VibingChat left
```

**期待される動作:**

- 現在のウィンドウの左側に新しいウィンドウが作成される
- チャットバッファが新しいウィンドウに表示される

### 4. 上分割（top）

**操作:**

```vim
:VibingChat top
```

**期待される動作:**

- 現在のウィンドウの上側に新しいウィンドウが作成される
- チャットバッファが新しいウィンドウに表示される

### 5. 下分割（bottom）

**操作:**

```vim
:VibingChat bottom
```

**期待される動作:**

- 現在のウィンドウの下側に新しいウィンドウが作成される
- チャットバッファが新しいウィンドウに表示される

### 6. バックグラウンド（back）

**操作:**

```vim
:VibingChat back
```

**期待される動作:**

- ウィンドウは作成されない
- チャットバッファはバックグラウンドで作成される
- 現在のウィンドウとバッファは変更されない

**検証ポイント:**

```lua
-- ウィンドウ数が変わらないことを確認
local before_count = #vim.api.nvim_list_wins()
-- :VibingChat back 実行
local after_count = #vim.api.nvim_list_wins()
assert(after_count == before_count)

-- バッファは作成されていることを確認
-- vim.fn.bufexists('vibing://chat-*') で確認
```

### 7. フローティングウィンドウ（float）

**操作:**

```vim
:VibingChat float
```

**期待される動作:**

- 中央にフローティングウィンドウが作成される
- チャットバッファが表示される
- 元のウィンドウは背景に残る

**検証ポイント:**

```lua
-- フローティングウィンドウかどうかを確認
local chat_win = vim.api.nvim_get_current_win()
local config = vim.api.nvim_win_get_config(chat_win)
assert(config.relative == "editor")
assert(config.width > 0)
assert(config.height > 0)
```

### 8. 既存のチャットファイルを開く

**前提条件:**

- `.vibing/chat/` ディレクトリに既存のチャットファイルがある

**操作:**

```vim
:VibingChat right .vibing/chat/chat-20260117-123456-abcd.vibing
```

**期待される動作:**

- 既存のチャットファイルが開かれる
- セッションIDが保持されている
- 会話履歴が表示される
- 指定された位置（right）にウィンドウが開く

**検証ポイント:**

```lua
-- フロントマターからsession_idを取得
-- 会話履歴が含まれていることを確認
```

### 9. 複数のチャットウィンドウ

**操作:**

```vim
:VibingChat right
:VibingChat left
```

**期待される動作:**

- 2つの独立したチャットバッファが作成される
- それぞれ異なるセッションIDを持つ
- 両方のチャットが独立して動作する

**検証ポイント:**

```lua
-- 2つのvibing://chat-*バッファが存在することを確認
local chat_buffers = {}
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("^vibing://chat%-") then
    table.insert(chat_buffers, buf)
  end
end
assert(#chat_buffers == 2)
```

### 10. ウィンドウサイズの調整

**操作:**

```vim
:VibingChat right
<C-w>10>  # 幅を10カラム増やす
```

**期待される動作:**

- チャットウィンドウのサイズが調整される
- バッファ内容が正しく再描画される

## 異常系テスト

### 11. 無効な位置指定

**操作:**

```vim
:VibingChat invalid_position
```

**期待される動作:**

- エラーメッセージが表示される、またはデフォルト位置にフォールバック
- Neovimがクラッシュしない

### 12. 存在しないファイルパス

**操作:**

```vim
:VibingChat /path/to/nonexistent/file.vibing
```

**期待される動作:**

- エラーメッセージが表示される
- 新しいチャットは作成されない

## クリーンアップ

**操作:**

```vim
# 全チャットウィンドウを閉じる
:bufdo if &ft == 'vibing' | bd! | endif
```

## 成功基準

- [ ] 全ての位置指定オプションが正しく動作する
- [ ] 既存のチャットファイルが開ける
- [ ] 複数のチャットウィンドウが共存できる
- [ ] ウィンドウサイズの調整が正しく動作する
- [ ] エラーハンドリングが適切に機能する

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/controller.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/window_manager.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/buffer.lua`
