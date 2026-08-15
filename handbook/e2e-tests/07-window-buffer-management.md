# E2Eテストケース: ウィンドウ/バッファ管理

## テストID

`E2E-WINDOW-001`

## テスト対象

チャットバッファとウィンドウの管理機能全般

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている

## テスト手順

### 1. バッファの作成と識別

**操作:**

```vim
:VibingChat
```

**期待される動作:**

- 新しいバッファが作成される
- バッファ番号が割り当てられる
- バッファ名が `vibing://chat-[timestamp]-[id]` 形式
- `buftype` が適切に設定される（`nofile` または `acwrite`）
- `filetype` が `vibing` に設定される

**検証ポイント:**

```lua
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_is_valid(bufnr))
assert(vim.bo[bufnr].filetype == "vibing")
local bufname = vim.api.nvim_buf_get_name(bufnr)
assert(bufname:match("^vibing://chat%-"))
```

### 2. 無名バッファの識別

**操作:**

```vim
:enew  # 無名バッファを作成
:VibingChat
```

**期待される動作:**

- 無名バッファが適切に識別される
- チャットバッファに置き換えられる
- 元の無名バッファは破棄される（または保持される）

**検証ポイント:**

```lua
local identifier = require("vibing.presentation.chat.modules.buffer_identifier")
local is_unnamed = identifier.is_unnamed_buffer(bufnr)
-- 期待: 無名バッファはtrue、名前付きバッファはfalse
```

### 3. ウィンドウのフォーカス管理

**操作:**

```vim
:vsplit
:VibingChat left
# 左側にチャットウィンドウが開く
# 右側の元のウィンドウにフォーカスを戻す
<C-w>l
```

**期待される動作:**

- ウィンドウフォーカスが正しく移動する
- 各ウィンドウが独立して操作できる

**検証ポイント:**

```lua
local current_win = vim.api.nvim_get_current_win()
local current_buf = vim.api.nvim_win_get_buf(current_win)
-- 現在のバッファがチャットバッファでないことを確認
```

### 4. ウィンドウのリサイズ

**操作:**

```vim
:VibingChat right
<C-w>20>  # 幅を20カラム増やす
<C-w>10+  # 高さを10行増やす
```

**期待される動作:**

- ウィンドウサイズが変更される
- バッファ内容が正しく再描画される
- テキストの折り返しが適切に処理される

**検証ポイント:**

```lua
local win = vim.api.nvim_get_current_win()
local width = vim.api.nvim_win_get_width(win)
local height = vim.api.nvim_win_get_height(win)
-- サイズが変更されていることを確認
```

### 5. 複数バッファの同時管理

**操作:**

```vim
:VibingChat right
:VibingChat left
:VibingChat bottom
```

**期待される動作:**

- 3つの独立したチャットバッファが作成される
- それぞれ異なるウィンドウに表示される
- 各バッファが独立して操作できる

**検証ポイント:**

```lua
local chat_bufs = {}
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[buf].filetype == "vibing" then
    table.insert(chat_bufs, buf)
  end
end
assert(#chat_bufs == 3)
```

### 6. バッファの切り替え

**操作:**

```vim
:VibingChat right
:VibingChat left
# 右のチャットバッファに切り替え
<C-w>l
# 左のチャットバッファに切り替え
<C-w>h
```

**期待される動作:**

- ウィンドウ間のフォーカス移動がスムーズ
- 各バッファの状態が保持される
- カーソル位置が保持される

### 7. バッファのリロード

**前提条件:**

- 既存のチャットファイルが存在する

**操作:**

```vim
:VibingChat .vibing/chat/existing.vibing
# ファイルを外部で編集
:e  # リロード
```

**期待される動作:**

- バッファがリロードされる
- 外部の変更が反映される
- フロントマターが正しく解析される

**検証ポイント:**

```lua
local reload = require("vibing.presentation.chat.modules.buffer_reload")
-- リロード機能が正しく動作することを確認
```

### 8. ウィンドウの閉じる

**操作:**

```vim
:VibingChat right
:q  # ウィンドウを閉じる
```

**期待される動作:**

- ウィンドウが閉じる
- バッファは保持される（back modeでない限り）
- チャット内容が保存される

**検証ポイント:**

```bash
# チャットファイルが保存されていることを確認
ls .vibing/chat/
```

### 9. バッファの削除

**操作:**

```vim
:VibingChat
:bd  # バッファを削除
```

**期待される動作:**

- `BufDelete` autocmdが発火する
- チャット内容が保存される
- Agent SDKジョブがキャンセルされる
- タイマーが停止される
- 関連するリソースがクリーンアップされる

**検証ポイント:**

```lua
-- バッファが無効になっていることを確認
assert(not vim.api.nvim_buf_is_valid(bufnr))
```

### 10. フローティングウィンドウの管理

**操作:**

```vim
:VibingChat float
```

**期待される動作:**

- フローティングウィンドウが中央に表示される
- ウィンドウ設定が正しく適用される:
  - `relative = "editor"`
  - `border` スタイル
  - `width` と `height` が適切

**検証ポイント:**

```lua
local win = vim.api.nvim_get_current_win()
local config = vim.api.nvim_win_get_config(win)
assert(config.relative == "editor")
assert(config.border ~= nil)
assert(config.width > 0)
assert(config.height > 0)
```

### 11. ウィンドウレイアウトの保持

**操作:**

```vim
:vsplit
:split
:VibingChat right
# 複雑なレイアウトを作成
:wincmd =  # ウィンドウサイズを均等化
```

**期待される動作:**

- レイアウトが保持される
- チャットウィンドウが既存のレイアウトに適切に統合される

### 12. タブページでの動作

**操作:**

```vim
:tabnew
:VibingChat
:tabnext
:tabprevious
```

**期待される動作:**

- 各タブページで独立してチャットバッファが管理される
- タブ切り替え時にバッファが保持される

## 異常系テスト

### 13. 無効なバッファ番号

**操作:**

```lua
local invalid_bufnr = 99999
local result = vim.api.nvim_buf_is_valid(invalid_bufnr)
```

**期待される動作:**

- `false` が返される
- エラーが発生しない

### 14. 無効なウィンドウ番号

**操作:**

```lua
local invalid_winnr = 99999
local result = vim.api.nvim_win_is_valid(invalid_winnr)
```

**期待される動作:**

- `false` が返される
- エラーが発生しない

### 15. バッファの強制削除

**操作:**

```vim
:VibingChat
# メッセージ送信中に
:bd!  # 強制削除
```

**期待される動作:**

- バッファが削除される
- 実行中のジョブがキャンセルされる
- Neovimがクラッシュしない
- チャット内容が保存される（可能であれば）

### 16. ウィンドウの強制クローズ

**操作:**

```vim
:VibingChat float
# フローティングウィンドウを強制的に閉じる
:lua vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
```

**期待される動作:**

- ウィンドウが閉じる
- バッファは保持される
- エラーが発生しない

## パフォーマンステスト

### 17. 大量のバッファ作成

**操作:**

```vim
# 20個のチャットバッファを作成
for i in range(20):
  :VibingChat back
```

**期待される動作:**

- 全てのバッファが正しく作成される
- メモリ使用量が許容範囲内
- パフォーマンスが低下しない

### 18. ウィンドウの頻繁な切り替え

**操作:**

```vim
:VibingChat right
:VibingChat left
# 100回切り替え
for i in range(100):
  <C-w>l
  <C-w>h
```

**期待される動作:**

- 切り替えがスムーズ
- メモリリークがない

## クリーンアップ

**操作:**

```vim
# 全チャットバッファを削除
:bufdo if &ft == 'vibing' | bd! | endif
# 全ウィンドウを閉じる
:only
```

## 成功基準

- [ ] バッファが正しく作成・識別される
- [ ] ウィンドウフォーカス管理が正しく動作する
- [ ] ウィンドウリサイズが正しく動作する
- [ ] 複数バッファの同時管理ができる
- [ ] バッファ切り替えが正しく動作する
- [ ] バッファリロードが正しく動作する
- [ ] ウィンドウ/バッファの削除が正しく動作する
- [ ] フローティングウィンドウが正しく管理される
- [ ] エラーハンドリングが適切に機能する
- [ ] パフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/buffer.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/window_manager.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/buffer_identifier.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/modules/buffer_reload.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/view.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/plugin/vibing.lua` (autocmd設定)
