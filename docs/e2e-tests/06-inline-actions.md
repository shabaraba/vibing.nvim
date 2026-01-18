# E2Eテストケース: インライン機能

## テストID

`E2E-INLINE-001`

## テスト対象

`:VibingInline` コマンドによるインラインアクション機能

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- Agent SDKが正しく設定されている
- テスト用のコードファイルが存在する

## テスト手順

### 1. アクション選択ピッカー

**操作:**

```vim
:VibingInline
```

**期待される動作:**

- インラインアクション選択ピッカーが表示される
- 以下のオプションが表示される:
  - `fix` - バグ修正
  - `feat` - 機能追加
  - `explain` - コード説明
  - `refactor` - リファクタリング
  - `test` - テスト追加
  - カスタムプロンプト入力

**検証ポイント:**

- ピッカーウィンドウが表示されること
- キーボード操作（j/k, Enter, ESC）が機能すること

### 2. fix アクション（バグ修正）

**操作:**

```vim
:edit buggy_code.lua
# Visual modeで修正したいコードを選択
V
10j
:VibingInline fix
```

**期待される動作:**

1. 選択範囲が送信される
2. Agent SDKが修正候補を返す
3. プレビューウィンドウが表示される（デフォルト動作）
4. 差分が表示される

**検証ポイント:**

```lua
-- プレビューウィンドウが開いていることを確認
local wins = vim.api.nvim_list_wins()
-- フローティングウィンドウが存在することを確認
```

### 3. feat アクション（機能追加）

**操作:**

```vim
:edit existing_code.lua
# 機能を追加したい箇所を選択
V
5j
:VibingInline feat
```

**期待される動作:**

- 選択範囲に基づいて機能追加の提案が生成される
- プレビューで変更内容が確認できる
- 適用/却下を選択できる

### 4. explain アクション（コード説明）

**操作:**

```vim
:edit complex_code.lua
# 説明してほしいコードを選択
V
15j
:VibingInline explain
```

**期待される動作:**

- フローティングウィンドウに説明が表示される
- コードは変更されない（output modeで動作）
- 説明が日本語で表示される

**検証ポイント:**

```lua
-- 元のバッファが変更されていないことを確認
local modified = vim.bo.modified
assert(modified == false)
```

### 5. refactor アクション（リファクタリング）

**操作:**

```vim
:edit messy_code.lua
# リファクタリング対象を選択
V
20j
:VibingInline refactor
```

**期待される動作:**

- リファクタリング提案が生成される
- プレビューで変更内容が確認できる
- コードの機能は変更されないことが保証される

### 6. test アクション（テスト追加）

**操作:**

```vim
:edit function.lua
# テストを追加したい関数を選択
V
10j
:VibingInline test
```

**期待される動作:**

- テストコードの提案が生成される
- テストファイルへの追加または新規作成が提案される

### 7. カスタムプロンプト

**操作:**

```vim
:edit code.lua
V
5j
:VibingInline "この関数をTypeScriptに変換してください"
```

**期待される動作:**

- カスタムプロンプトが処理される
- 選択範囲とプロンプトが統合されてAgent SDKに送信される
- 結果がプレビュー表示される

### 8. プレビューモード（差分表示）

**操作:**

```vim
:edit code.lua
V
5j
:VibingInline fix
# プレビューウィンドウが表示される
```

**期待される動作:**

- フローティングウィンドウに差分が表示される
- 以下のキーマップが機能する:
  - `<CR>` または `a` - 適用
  - `ESC` または `r` - 却下
- 適用時に元のバッファが変更される
- 却下時にウィンドウが閉じる

**検証ポイント:**

```lua
-- 適用後にバッファが変更されていることを確認
assert(vim.bo.modified == true)
```

### 9. ダイレクトモード（即座に適用）

**設定:**

```lua
require("vibing").setup({
  inline = {
    mode = "direct"  -- プレビューなしで即座に適用
  }
})
```

**操作:**

```vim
V
5j
:VibingInline fix
```

**期待される動作:**

- プレビューウィンドウが表示されない
- 変更が即座にバッファに適用される
- アンドゥで元に戻せる

### 10. タスクキュー（連続実行）

**操作:**

```vim
# 複数のインラインアクションを連続で実行
:VibingInline fix
# すぐに次のコマンドを実行
:VibingInline refactor
```

**期待される動作:**

- 最初のタスクが完了するまで2番目のタスクがキューイングされる
- タスクが順番に実行される
- UIに実行中のタスク数が表示される（オプション）

**検証ポイント:**

```lua
local queue = require("vibing.application.inline.modules.task_queue")
-- キューが空になるまで待機
vim.wait(10000, function()
  return queue.is_empty()
end)
```

### 11. 選択範囲なしでの実行

**操作:**

```vim
:edit code.lua
# Visual modeに入らずに実行
:VibingInline fix
```

**期待される動作:**

- 警告メッセージが表示される: "No text selected"
- コマンドが実行されない

### 12. キャンセル操作

**操作:**

```vim
V
5j
:VibingInline fix
# レスポンスを待っている間に
<C-c>
```

**期待される動作:**

- タスクがキャンセルされる
- プレビューウィンドウが閉じる（開いている場合）
- エラーメッセージが表示される

## 異常系テスト

### 13. Agent SDKエラー

**前提条件:**

- Agent SDKが起動していない

**操作:**

```vim
V
5j
:VibingInline fix
```

**期待される動作:**

- エラーメッセージが表示される
- Neovimがクラッシュしない

### 14. 無効なアクション名

**操作:**

```vim
:VibingInline invalid_action
```

**期待される動作:**

- カスタムプロンプトとして扱われる
- またはエラーメッセージが表示される

### 15. 巨大なコード選択

**操作:**

```vim
# 10000行のコードを選択
ggVG
:VibingInline fix
```

**期待される動作:**

- 警告メッセージが表示される（オプション）
- または正常に処理される
- メモリ使用量が異常に増加しない
- タイムアウトが適切に処理される

### 16. 連続した大量のタスク

**操作:**

```vim
# 10個のタスクを連続で送信
for i in range(10):
  V5j
  :VibingInline fix
```

**期待される動作:**

- 全てのタスクがキューイングされる
- 順番に実行される
- メモリリークがない
- Neovimがフリーズしない

## パフォーマンステスト

### 17. 大きなファイルでのインライン実行

**前提条件:**

- 1000行以上のファイル

**操作:**

```vim
# 100行を選択
V100j
:VibingInline fix
```

**期待される動作:**

- レスポンス時間が許容範囲内（30秒以内）
- UIがフリーズしない

### 18. 差分表示のパフォーマンス

**操作:**

```vim
# 大きな変更を生成
V500j
:VibingInline refactor
```

**期待される動作:**

- 差分計算が1秒以内に完了
- プレビューウィンドウがスムーズに表示される

## クリーンアップ

**操作:**

```vim
# 全てのタスクをキャンセル
:lua require("vibing.application.inline.modules.task_queue").clear()
# フローティングウィンドウを閉じる
:lua vim.api.nvim_win_close(win, true)
```

## 成功基準

- [ ] アクション選択ピッカーが正しく動作する
- [ ] 全ての事前定義アクション（fix/feat/explain/refactor/test）が機能する
- [ ] カスタムプロンプトが処理される
- [ ] プレビューモードが正しく動作する
- [ ] ダイレクトモードが正しく動作する
- [ ] タスクキューが順番に処理する
- [ ] キャンセル操作が正しく動作する
- [ ] エラーハンドリングが適切に機能する
- [ ] パフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/inline/controller.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/inline/use_case.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/inline/modules/action_config.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/inline/modules/prompt_builder.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/inline/modules/task_queue.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/inline/modules/execution.lua`
