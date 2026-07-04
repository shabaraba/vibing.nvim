# E2Eテストケース: Workspace統合機能

## テストID

`E2E-WORKSPACE-001`

## テスト対象

`/vibing-workspace-create`, `/vibing-workspace-enter`, `/vibing-workspace-done`, `/vibing-workspace-list`
のスラッシュコマンドによるworkspace（git worktreeベースの隔離開発環境）統合機能

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- gitリポジトリ内で実行している
- gitコマンドが利用可能

## テスト手順

### 1. 新規Workspaceの作成

**操作:**

```vim
:VibingChat
i
/vibing-workspace-create ログイン機能の実装
<CR>
```

**期待される動作:**

1. `vim.ui.input` でdescriptionとbranch名の確認プロンプトが表示される
2. 確定すると `.vibing/workspace/active/<id>/` にworkspaceディレクトリが作成される
3. `.vibing/workspace/active/<id>/worktree/` にgit worktreeが作成される（新しいブランチも作成される）
4. `.vibing/workspace/active/<id>/meta.yaml` と `plan.md` が作成される
5. 現在のチャットバッファがそのworkspaceに紐付く（frontmatterに `workspace_id`, `working_dir` が追加される）
6. チャットバッファに `Workspace \`<id>\` created at \`...\`.` のメッセージが追記される

**検証ポイント:**

```bash
# workspaceディレクトリが作成されていることを確認
ls .vibing/workspace/active/
# <id>/ が存在

ls .vibing/workspace/active/<id>/
# worktree/, meta.yaml, plan.md が存在

# git worktreeが作成されていることを確認
git worktree list
# .vibing/workspace/active/<id>/worktree が一覧に追加されている
```

```lua
-- チャットバッファのfrontmatterを確認
local frontmatter = require("vibing.domain.chat.frontmatter")
-- workspace_id と working_dir (.vibing/workspace/active/<id>/worktree) が設定されている
```

### 2. 既存Workspaceへの参加（enter）

**前提条件:**

- workspace `<id>` が既に active な状態で存在する

**操作:**

```vim
:VibingChat
i
/vibing-workspace-enter <id>
<CR>
```

**期待される動作:**

- 引数を省略した場合は `vim.ui.select` でactiveなworkspace一覧から選択できる
- 現在のチャットバッファがそのworkspaceに紐付く
- `Entered workspace: <id>` の通知が表示される
- 既にworkspaceに紐付いているチャットで実行した場合はエラーになる

### 3. Workspace内でのメッセージ送信・ファイル操作

**操作:**

```vim
:VibingChat
i
/vibing-workspace-create テスト機能
<CR>
i
新しいファイルを作成してください: src/new_feature.lua
<CR>
```

**期待される動作:**

- メッセージ送信時、Agent SDKに `--cwd` としてworkspaceのworktreeパスが渡される
- Claudeが作成するファイルはworktreeディレクトリ内に作成される
- メインリポジトリには影響しない

**検証ポイント:**

```bash
# worktreeディレクトリにファイルが作成されている
ls .vibing/workspace/active/<id>/worktree/src/new_feature.lua

# メインリポジトリには存在しない
ls src/new_feature.lua
# ファイルが見つからない
```

### 4. 一覧表示（list）

**操作:**

```vim
:VibingChat
i
/vibing-workspace-list
<CR>
```

**期待される動作:**

- activeなworkspace一覧がチャットバッファに追記される（`- \`<id>\` - <description> (<branch>)` 形式）

```vim
i
/vibing-workspace-list done
<CR>
```

**期待される動作:**

- doneなworkspace一覧が表示される

**検証ポイント:**

```bash
# 引数なしはactive、"done"引数はdoneディレクトリの一覧と一致すること
ls .vibing/workspace/active/
ls .vibing/workspace/done/
```

### 5. Workspaceの完了（done）

**操作:**

```vim
:VibingChat
i
/vibing-workspace-done <id>
<CR>
```

**期待される動作:**

1. `plan.md` に未完了のTODOがある場合、または対象ブランチが未マージの場合は確認ダイアログが表示される
2. 確定すると `git worktree remove` でworktreeが削除される
3. workspaceディレクトリが `.vibing/workspace/active/<id>/` から `.vibing/workspace/done/<id>/` に移動する
4. `Workspace done: <id>` の通知が表示される

**検証ポイント:**

```bash
# worktreeが削除されている
git worktree list
# <id>用のworktreeが存在しない

# workspaceディレクトリがdoneに移動している
ls .vibing/workspace/done/<id>/
# meta.yaml, plan.md が存在（worktree/ ディレクトリは削除済み）

ls .vibing/workspace/active/<id>
# 存在しない
```

### 6. Workspace削除後もチャットファイルは影響を受けない

**操作:**

```vim
:VibingChat
i
/vibing-workspace-create 一時作業
<CR>
:w
:q

# workspaceを完了させる
:VibingChat
i
/vibing-workspace-done <id>
<CR>
```

**期待される動作:**

- worktreeを削除してもチャットファイルは `.vibing/chat/` に残る
- チャットを再度開いてもファイル自体は読める（ただし `working_dir` の指す先は既に存在しないため、再開時は要確認）

## 異常系テスト

### 7. 既にworkspaceに紐付いたチャットで再度create/enter

**操作:**

```vim
:VibingChat
i
/vibing-workspace-create テストA
<CR>
i
/vibing-workspace-create テストB
<CR>
```

**期待される動作:**

- 2回目の `/vibing-workspace-create` はエラーメッセージが表示される
  （"This chat is already bound to workspace ... Open a new chat to start another workspace."）
- 新しいworkspaceは作成されない

### 8. 存在しないworkspace_idを指定

**操作:**

```vim
:VibingChat
i
/vibing-workspace-enter nonexistent-id
<CR>
```

**期待される動作:**

- エラーメッセージが表示される: "No active workspace found: nonexistent-id"

### 9. workspaceに紐付いていないチャットで /vibing-workspace-done を引数なしで実行

**操作:**

```vim
:VibingChat
i
/vibing-workspace-done
<CR>
```

**期待される動作:**

- エラーメッセージが表示される: "This chat is not bound to a workspace. Usage: /vibing-workspace-done <workspace_id>"

### 10. gitリポジトリ外での実行

**前提条件:**

- gitリポジトリではないディレクトリで実行

**操作:**

```vim
:VibingChat
i
/vibing-workspace-create テスト
<CR>
```

**期待される動作:**

- エラーメッセージが表示される
- workspaceが作成されない
- Neovimがクラッシュしない

## クリーンアップ

**操作:**

```bash
# 全workspaceのworktreeを削除
git worktree list --porcelain | grep "worktree" | grep ".vibing/workspace/" | while read -r _ path; do
  git worktree remove "$path"
done

# workspaceディレクトリとチャットファイルを削除
rm -rf .vibing/workspace/
rm -rf .vibing/chat/
```

## 成功基準

- [ ] `/vibing-workspace-create` でworktree・meta.yaml・plan.mdが作成される
- [ ] チャットバッファがworkspaceに正しく紐付く（`workspace_id`, `working_dir` frontmatter）
- [ ] `/vibing-workspace-enter` で既存のactive workspaceに別チャットを紐付けられる
- [ ] `/vibing-workspace-list` でactive/doneの一覧が正しく表示される
- [ ] `/vibing-workspace-done` でworktreeが削除され、workspaceがdoneに移動する
- [ ] メッセージ送信時に `--cwd` がworkspaceのworktreeパスとして伝播する
- [ ] 既にworkspaceに紐付いたチャットでの再create/enterがエラーになる
- [ ] エラーハンドリングが適切に機能する

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/handlers/workspace_create.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/handlers/workspace_enter.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/handlers/workspace_done.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/application/chat/handlers/workspace_list.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/workspace/manager.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/workspace/meta.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/workspace/chat_binding.lua`
