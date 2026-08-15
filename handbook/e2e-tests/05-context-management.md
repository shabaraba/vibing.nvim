# E2Eテストケース: コンテキスト管理機能

## テストID

`E2E-CONTEXT-001`

## テスト対象

`:VibingContext` と `:VibingClearContext` コマンドによるコンテキスト管理

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- テスト用のファイルが存在する

## テスト手順

### 1. 現在のバッファをコンテキストに追加

**操作:**

```vim
:edit test.lua
:VibingContext
```

**期待される動作:**

- 現在のバッファ (`test.lua`) がコンテキストに追加される
- クリップボードにコンテキストがコピーされる
- 通知が表示される: "Added to context: test.lua"

**検証ポイント:**

```lua
local context = require("vibing.application.context.manager")
local contexts = context.get_manual()
assert(#contexts == 1)
assert(contexts[1]:match("@file:.*test%.lua"))
```

```vim
" クリップボードの内容を確認
:echo @+
" 期待される内容: @file:test.lua
```

### 2. ファイルパスを指定してコンテキストに追加

**操作:**

```vim
:VibingContext src/main.lua
```

**期待される動作:**

- 指定されたファイル (`src/main.lua`) がコンテキストに追加される
- ファイルが開かれていなくても追加できる
- 相対パスが正規化される

**検証ポイント:**

```lua
local contexts = context.get_manual()
assert(#contexts == 2)  -- test.lua + src/main.lua
assert(contexts[2]:match("@file:src/main%.lua"))
```

### 3. Visual範囲をコンテキストに追加

**操作:**

```vim
:edit test.lua
# 10-20行目を選択
:10,20VibingContext
```

**期待される動作:**

- 選択範囲がコンテキストに追加される
- 行範囲情報が含まれる

**検証ポイント:**

```lua
local contexts = context.get_manual()
-- 期待される形式: @file:test.lua:L10-L20
assert(contexts[#contexts]:match("@file:.*test%.lua:L10%-L20"))
```

### 4. oil.nvimバッファから複数ファイルを選択

**前提条件:**

- oil.nvimがインストールされている
- oil.nvimバッファが開いている
- 複数のファイルが選択されている

**操作:**

```vim
# oil.nvimで複数ファイルを選択（マーク）
:VibingContext
```

**期待される動作:**

- 選択された全てのファイルがコンテキストに追加される
- ディレクトリは無視される（警告が表示される）
- 各ファイルに対して個別の `@file:` エントリが作成される

**検証ポイント:**

```lua
local contexts = context.get_manual()
-- 選択したファイル数だけコンテキストが増えていることを確認
```

### 5. コンテキストの重複追加

**操作:**

```vim
:edit test.lua
:VibingContext
:VibingContext  # 同じファイルを再度追加
```

**期待される動作:**

- 重複したコンテキストは追加されない
- 通知が表示される: "Already in context: test.lua" （または類似のメッセージ）

**検証ポイント:**

```lua
local contexts = context.get_manual()
-- test.luaが1つだけ存在することを確認
local count = 0
for _, ctx in ipairs(contexts) do
  if ctx:match("test%.lua") then
    count = count + 1
  end
end
assert(count == 1)
```

### 6. コンテキストのクリア

**操作:**

```vim
:VibingContext test1.lua
:VibingContext test2.lua
:VibingContext test3.lua
:VibingClearContext
```

**期待される動作:**

- 全てのマニュアルコンテキストがクリアされる
- 通知が表示される: "Context cleared"

**検証ポイント:**

```lua
local contexts = context.get_manual()
assert(#contexts == 0)
```

### 7. チャットへのコンテキスト反映

**操作:**

```vim
:VibingContext test.lua
:VibingChat
```

**期待される動作:**

- チャットバッファのコンテキストセクションにファイルが表示される

**検証ポイント:**

```markdown
<!-- Context: -->

@file:test.lua
```

### 8. コンテキストの自動収集

**前提条件:**

- 複数のバッファが開いている

**操作:**

```vim
:edit file1.lua
:edit file2.lua
:edit file3.lua
# コンテキストを手動で追加せずにチャットを開く
:VibingChat
```

**期待される動作:**

- 開いているバッファが自動的にコンテキストとして収集される
- チャットバッファのコンテキストセクションに表示される

**検証ポイント:**

```lua
local context = require("vibing.application.context.manager")
local all_contexts = context.get_all()
-- 開いているファイルがコンテキストに含まれていることを確認
```

### 9. プロンプトへのコンテキスト統合

**操作:**

```vim
:VibingContext test.lua
:VibingChat
i
このファイルについて教えてください
<CR>
```

**期待される動作:**

- メッセージ送信時にコンテキストがプロンプトに統合される
- Agent SDKに渡されるプロンプトにコンテキスト情報が含まれる

**検証ポイント:**

```lua
-- send_message.luaで構築されるプロンプトを確認
-- コンテキストファイルの内容が含まれていることを確認
```

## 異常系テスト

### 10. 存在しないファイルをコンテキストに追加

**操作:**

```vim
:VibingContext /path/to/nonexistent/file.lua
```

**期待される動作:**

- エラーメッセージが表示される
- コンテキストには追加されない

### 11. 空のファイルパス

**操作:**

```vim
:VibingContext
# 引数なし、かつ現在のバッファが無名バッファ
```

**期待される動作:**

- 警告メッセージが表示される: "No file to add to context"
- 処理がスキップされる

### 12. ディレクトリをコンテキストに追加（oil.nvim経由）

**操作:**

```vim
# oil.nvimでディレクトリを選択
:VibingContext
```

**期待される動作:**

- ディレクトリは無視される
- 警告メッセージが表示される: "Skipping directory: [dir_name]"
- ファイルのみがコンテキストに追加される

### 13. 巨大なファイルをコンテキストに追加

**前提条件:**

- 10MB以上の巨大なファイルが存在する

**操作:**

```vim
:VibingContext huge_file.txt
```

**期待される動作:**

- ファイルサイズの警告が表示される（オプション）
- または正常に追加される
- メモリ使用量が異常に増加しない

**検証ポイント:**

```bash
# メモリ使用量を監視
top -p $(pgrep nvim)
```

### 14. 大量のファイルをコンテキストに追加

**操作:**

```vim
# 100個のファイルをコンテキストに追加
for i in range(100):
  :VibingContext file${i}.lua
```

**期待される動作:**

- 全てのファイルが正しく追加される
- パフォーマンスが許容範囲内
- メモリリークがない

**検証ポイント:**

```lua
local contexts = context.get_manual()
assert(#contexts == 100)
```

## パフォーマンステスト

### 15. コンテキスト収集のパフォーマンス

**操作:**

```vim
# 50個のバッファを開く
for i in range(50):
  :edit file${i}.lua

# コンテキスト収集時間を測定
:lua local start = vim.loop.hrtime()
:lua require("vibing.infrastructure.context.collector").collect_buffers()
:lua local elapsed = (vim.loop.hrtime() - start) / 1e6
:lua print("Elapsed:", elapsed, "ms")
```

**期待される動作:**

- 収集時間が50ms以下（目標値）
- UIがフリーズしない

### 16. コンテキストフォーマットのパフォーマンス

**操作:**

```vim
# 100個のコンテキストを追加
# プロンプトフォーマット時間を測定
:lua local start = vim.loop.hrtime()
:lua require("vibing.infrastructure.context.formatter").format_prompt(...)
:lua local elapsed = (vim.loop.hrtime() - start) / 1e6
:lua print("Elapsed:", elapsed, "ms")
```

**期待される動作:**

- フォーマット時間が100ms以下（目標値）

## クリーンアップ

**操作:**

```vim
:VibingClearContext
:bufdo bd!
```

## 成功基準

- [ ] ファイルがコンテキストに正しく追加される
- [ ] Visual範囲がコンテキストに追加される
- [ ] oil.nvimからの複数選択が動作する
- [ ] コンテキストの重複が防止される
- [ ] コンテキストのクリアが正しく動作する
- [ ] チャットにコンテキストが反映される
- [ ] 自動収集が正しく動作する
- [ ] プロンプトへの統合が正しく動作する
- [ ] エラーハンドリングが適切に機能する
- [ ] パフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/context/controller.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/context/manager.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/context/collector.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/context/formatter.lua`
