# E2Eテストケース: Worktree統合機能

## テストID

`E2E-WORKTREE-001`

## テスト対象

`:VibingChatWorktree` コマンドによるgit worktree統合機能

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- gitリポジトリ内で実行している
- gitコマンドが利用可能

## テスト手順

### 1. 新規Worktreeの作成

**操作:**

```vim
:VibingChatWorktree feature-test
```

**期待される動作:**

1. git worktreeが `.git/worktrees/` に作成される
2. 新しいブランチ `feature-test` が作成される
3. worktreeディレクトリが作成される（デフォルト: `../vibing.nvim-feature-test`）
4. 必要な設定ファイルがコピーされる:
   - `tsconfig.json`
   - `package.json`
   - `.gitignore`
5. `node_modules` がシンボリックリンクで共有される
6. チャットファイルはメインリポジトリの `.vibing/chat/` に保存される
7. チャットバッファが開く
8. `cwd` が worktreeディレクトリに設定される

**検証ポイント:**

```bash
# worktreeが作成されていることを確認
git worktree list

# 期待される出力:
# /path/to/vibing.nvim       [main]
# /path/to/vibing.nvim-feature-test  [feature-test]

# 設定ファイルがコピーされていることを確認
ls ../vibing.nvim-feature-test/
# tsconfig.json, package.json, .gitignore が存在

# node_modulesがシンボリックリンクであることを確認
ls -la ../vibing.nvim-feature-test/node_modules
# lrwxr-xr-x ... node_modules -> /path/to/vibing.nvim/node_modules

# チャットファイルがメインリポジトリに保存されることを確認
ls .vibing/chat/
# chat-*.vibing が存在（worktreeディレクトリではなくメインリポジトリ）
```

```lua
-- Luaから確認
local session = require("vibing.domain.chat.session")
local current_session = session.get_current()
assert(current_session.cwd:match("vibing%.nvim%-feature%-test"))
```

### 2. 既存ブランチでWorktreeを作成

**前提条件:**

- ブランチ `existing-branch` が既に存在する

**操作:**

```vim
:VibingChatWorktree existing-branch
```

**期待される動作:**

- 既存のブランチをチェックアウトする
- 新しいworktreeが作成される
- 設定ファイルがコピーされる

**検証ポイント:**

```bash
git worktree list
# existing-branch用のworktreeが作成されている
```

### 3. 位置指定付きWorktree作成

**操作:**

```vim
:VibingChatWorktree right feature-ui
```

**期待される動作:**

- worktreeが作成される
- チャットウィンドウが右側に開く
- 全ての設定が正しく適用される

### 4. Worktreeでのメッセージ送信

**操作:**

```vim
:VibingChatWorktree feature-test
i
このworktreeで作業しています
<CR>
```

**期待される動作:**

- メッセージが送信される
- Agent SDKに `--cwd` 引数でworktreeパスが渡される
- レスポンスが正しく表示される

**検証ポイント:**

```lua
-- SendMessage use caseでcwdが設定されていることを確認
local send_message = require("vibing.application.chat.send_message")
-- opts.cwd が worktreeパスに設定されている
```

### 5. Worktree内でのファイル操作

**操作:**

```vim
:VibingChatWorktree feature-test
i
新しいファイルを作成してください: src/new_feature.lua
<CR>
# Claudeが新しいファイルを作成する
```

**期待される動作:**

- ファイルがworktreeディレクトリ内に作成される
- メインリポジトリには影響しない

**検証ポイント:**

```bash
# worktreeディレクトリにファイルが作成されている
ls ../vibing.nvim-feature-test/src/new_feature.lua

# メインリポジトリには存在しない
ls src/new_feature.lua
# ファイルが見つからない
```

### 6. チャットファイルの永続化

**操作:**

```vim
:VibingChatWorktree feature-test
i
テストメッセージ
<CR>
:w
:q

# worktreeを削除
:!git worktree remove ../vibing.nvim-feature-test

# チャットファイルが残っていることを確認
:VibingChat .vibing/chat/chat-*.vibing
```

**期待される動作:**

- worktreeを削除してもチャットファイルは残る
- チャットファイルがメインリポジトリの `.vibing/chat/` にある
- チャットを再開できる

**検証ポイント:**

```bash
# worktreeが削除されている
git worktree list
# feature-testのworktreeが存在しない

# チャットファイルは残っている
ls .vibing/chat/
# chat-*.vibing が存在
```

### 7. 複数Worktreeの同時管理

**操作:**

```vim
:VibingChatWorktree right feature-a
:VibingChatWorktree left feature-b
```

**期待される動作:**

- 2つのworktreeが作成される
- それぞれ独立したチャットセッション
- 各チャットが正しいworktreeディレクトリを参照

**検証ポイント:**

```bash
git worktree list
# 2つのworktreeが存在
```

```lua
-- 各チャットバッファが異なるcwdを持つことを確認
```

### 8. Worktreeからメインリポジトリへの切り替え

**操作:**

```vim
:VibingChatWorktree feature-test
# worktreeで作業
:q

# メインリポジトリで新しいチャット
:VibingChat
i
メインリポジトリで作業中
<CR>
```

**期待される動作:**

- メインリポジトリの `cwd` が使用される
- worktreeのパスは使用されない

## 異常系テスト

### 9. 無効なブランチ名

**操作:**

```vim
:VibingChatWorktree "invalid branch name with spaces"
```

**期待される動作:**

- エラーメッセージが表示される
- worktreeが作成されない
- Neovimがクラッシュしない

### 10. 既存のWorktreeと同名

**前提条件:**

- `feature-test` worktreeが既に存在する

**操作:**

```vim
:VibingChatWorktree feature-test
```

**期待される動作:**

- エラーメッセージが表示される: "worktree already exists"
- 既存のworktreeに切り替える、または何もしない

### 11. gitリポジトリ外での実行

**前提条件:**

- gitリポジトリではないディレクトリで実行

**操作:**

```vim
:VibingChatWorktree feature-test
```

**期待される動作:**

- エラーメッセージが表示される
- コマンドが失敗する
- Neovimがクラッシュしない

### 12. 設定ファイルのコピー失敗

**前提条件:**

- `tsconfig.json` が存在しない

**操作:**

```vim
:VibingChatWorktree feature-test
```

**期待される動作:**

- 警告メッセージが表示される（オプション）
- worktreeは作成されるが、該当ファイルはコピーされない
- 処理は継続される

### 13. node_modulesのシンボリックリンク失敗

**前提条件:**

- `node_modules` が存在しない

**操作:**

```vim
:VibingChatWorktree feature-test
```

**期待される動作:**

- 警告メッセージが表示される
- worktreeは作成される
- ユーザーに手動で `npm install` するよう通知される

### 14. Worktree削除時のチャットファイル保護

**操作:**

```bash
# 誤ってworktreeディレクトリごと削除
rm -rf ../vibing.nvim-feature-test
```

**期待される動作:**

- チャットファイルはメインリポジトリにあるため影響を受けない
- チャット履歴が失われない

**検証ポイント:**

```bash
ls .vibing/chat/
# チャットファイルが残っている
```

## パフォーマンステスト

### 15. Worktree作成時間

**操作:**

```bash
# 作成時間を測定
time nvim -c ":VibingChatWorktree perf-test" -c ":q"
```

**期待される動作:**

- 作成時間が5秒以内（目標値）
- UIがブロックされない

### 16. 大量のWorktree

**操作:**

```bash
# 10個のworktreeを作成
for i in {1..10}; do
  nvim -c ":VibingChatWorktree feature-$i" -c ":q"
done
```

**期待される動作:**

- 全てのworktreeが正しく作成される
- node_modulesが共有されるためディスク使用量が最小限

**検証ポイント:**

```bash
git worktree list
# 10個のworktreeが存在

du -sh */node_modules
# 全て同じinodeを指している（シンボリックリンク）
```

## クリーンアップ

**操作:**

```bash
# 全worktreeを削除
git worktree list --porcelain | grep "worktree" | grep -v "$(pwd)" | while read -r line; do
  path=$(echo $line | cut -d' ' -f2)
  git worktree remove "$path"
done

# チャットファイルを削除
rm -rf .vibing/chat/
```

## 成功基準

- [ ] Worktreeが正しく作成される
- [ ] 設定ファイルが正しくコピーされる
- [ ] node_modulesが共有される
- [ ] チャットファイルがメインリポジトリに保存される
- [ ] cwdが正しく設定される
- [ ] メッセージ送信時にcwdが伝播する
- [ ] 複数Worktreeの同時管理ができる
- [ ] Worktree削除後もチャットファイルが残る
- [ ] エラーハンドリングが適切に機能する
- [ ] パフォーマンスが許容範囲内

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/presentation/chat/controller.lua` (handle_open_worktree)
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/use_case.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/domain/chat/session.lua` (cwd管理)
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/send_message.lua` (cwd伝播)
