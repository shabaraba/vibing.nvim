# vibing-workspace: Worktree開発ワークフローの再設計

## 背景・課題

`:VibingChatWorktree`によるworktree開発は以下の課題があった。

- セッション切り替えが煩雑で、複数worktree間でチャットのコンテキストが混線するバグが疑われる
- worktreeのライフサイクル（進行中/完了）を追跡する仕組みがなく、`.worktrees/`配下に放置されがち
- worktree関連の状態が`.vibing/`の外（リポジトリルート直下の`.worktrees/`）に散らばっている

## ゴール

- worktreeに紐づく作業を「workspace」という単位で管理し、状態・計画・関連チャットを`.vibing/workspace/`配下に一元化する
- workspaceの作成・移動・完了・一覧を専用スラッシュコマンドで対話的に行えるようにする
- 1つのチャットバッファは1つのworkspaceにのみ恒久的に紐付き、コンテキストの混線を構造的に防ぐ

## 非ゴール

- 既存workspace/worktreeの自動マイグレーション（`.worktrees/`から`.vibing/workspace/`への変換）
- workspace単位のブランチ命名規則の強制（ユーザー確認を経てAIが提案する程度に留める）

## ディレクトリ構成

```text
.vibing/workspace/
├── .counter                          # グローバル連番（プレーンテキスト、次に使う番号）
├── active/
│   └── 0001-fix-auth-session-bug/
│       ├── meta.yaml
│       ├── plan.md
│       └── worktree/                 # git worktree実体
└── done/
    └── 0002-refactor-permission-ui/
        ├── meta.yaml
        └── plan.md                   # worktree/ は削除済み
```

- 連番はグローバルに単調増加し、doneに移動しても再利用しない（`0001`のように会話上で一意に参照できることを重視）
- `workspace_id`はディレクトリ名そのもの（`<連番>-<branch>`）
- チャットファイル自体は既存の`chat.save_dir`設定に従って通常通り保存される。workspace側は相対パス参照（`meta.yaml`の`chat_files`）を持つのみ

## 既存機構との関係（破壊的変更）

- `:VibingChatWorktree`コマンド、`lua/vibing/infrastructure/worktree/manager.lua`、`.worktrees/`および`.vibing/worktrees/<branch>/`という保存規約は廃止し、本機構に統合する
- 既存の`.worktrees/`配下の作業は自動移行しない。ユーザーが個別に`git worktree remove`等で手動整理する
- ドキュメント（`.claude/rules/commands-reference.md`, `architecture.md`）から`:VibingChatWorktree`関連の記述を除去し、本機構の説明に置き換える

## スラッシュコマンド

既存のチャット内スラッシュコマンド（`/context`, `/model`等）と同様の位置付けだが、ユーザー定義のプロジェクトカスタムコマンド（`.claude/commands/`）との衝突を避けるため`vibing-`プレフィックスを付与する。

実装は`lua/vibing/application/chat/handlers/`配下に以下を追加し、共通ロジックは`lua/vibing/infrastructure/workspace/manager.lua`（および`counter.lua`）に集約する。

### `/vibing-workspace-create`

1. チャット内でAIが「どんな作業をするか」を対話的にヒアリングする
2. ヒアリング結果から、`title_generator.lua`と同様の仕組み（`config.language`を考慮）でAIが2つの文字列を生成する
   - `description`: 設定言語（例: 日本語）での作業内容ラベル
   - `branch`: 英語kebab-caseのブランチ名
3. 両方をユーザーに提示し、必要なら修正してもらってから確定する
4. `.counter`をインクリメントして`workspace_id`（例: `0001-fix-auth-session-bug`）を決定する
5. `.vibing/workspace/active/<workspace_id>/`を作成し、`meta.yaml`・`plan.md`をテンプレートからコピー、`git worktree add`で`worktree/`を作成する（既存`setup_environment`/`setup_node_modules`相当のロジックを流用: `.gitignore`, `package.json`等の設定ファイルコピー、`node_modules`シンボリックリンク）
6. `git worktree add`失敗時はエラーをそのまま表示し、作りかけの`active/<workspace_id>/`ディレクトリをロールバック（削除）する
7. 現在のチャットバッファをこの新規workspaceに紐付ける（frontmatterに`workspace_id`を書き込み、`working_dir`をworktreeパスに設定、`meta.yaml`の`chat_files`に追記）。この紐付けは恒久的

### `/vibing-workspace-enter [workspace_id]`

1. 引数省略時は`active`一覧からインタラクティブに選択させる
2. 実行したチャットバッファが既にいずれかのworkspaceに紐付いている場合はエラーで拒否する（例: 「このチャットは既に0003にバインドされています。新しいチャットを開いてください」）
3. 未バインドのバッファであれば、対象workspaceの`worktree/`を`working_dir`に設定し、frontmatterに`workspace_id`を書き込み、`meta.yaml`の`chat_files`に追記する。`session_id`は維持し会話履歴はリセットしない

### `/vibing-workspace-done [workspace_id]`

引数省略時は現在のバッファが紐付くworkspaceが対象。

1. `plan.md`内に未チェック項目（`- [ ]`）が残っていれば警告し、続行するか確認を求める
2. `git worktree remove worktree/`を実行する。未コミット変更がありgitがエラーを返した場合はそのままユーザーに提示する（`--force`は使わない。コミットまたはstashを促す）
3. ブランチが未マージであることが分かる場合は警告メッセージを添えるが、削除自体はブロックしない
4. worktree削除に成功したら、`active/<workspace_id>/`ディレクトリを`done/<workspace_id>/`へ移動する（`worktree/`は既に削除済みなので`meta.yaml`と`plan.md`のみ残る）

### `/vibing-workspace-list [done]`

- 引数なしは`active`のみ、`done`指定時は`done`一覧を表示する
- 表示は`番号 - description (branch)`のシンプルな一覧

## データスキーマ

### `meta.yaml`

```yaml
workspace_id: '0001-fix-auth-session-bug'
branch: 'fix-auth-session'
created_at: '2026-07-03T10:00:00'
description: '認証セッションのバグ修正'
chat_files:
  - '.vibing/chat/xxxxx.md'
```

### `plan.md`テンプレート

```markdown
# <description>

## TODO

- [ ]

## Notes
```

### チャットfrontmatter拡張

既存の`session_id`, `working_dir`等のフィールドに加え、以下を追加する。

```yaml
workspace_id: 0001-fix-auth-session-bug # このバッファが紐付くworkspace（一度設定されたら不変）
```

## worktree ⇄ チャットファイルのリンク同期

`ForkedChatScanner`（`lua/vibing/infrastructure/link/forked_chat_scanner.lua`）と同じScanner基底クラスのパターンで`WorkspaceChatScanner`を追加する。

- `:VibingSetFileTitle`によりチャットファイル名が変更された際、対応する`meta.yaml`の`chat_files`配列内の該当パスを新しいファイル名に更新する
- 既存の`forked_from`同期の仕組みと並行して動作させる（forkとworkspace紐付けは独立した概念）

## エラーハンドリング方針

- `workspace_id`の衝突は連番がグローバル一意のため実質発生しない
- 既にworkspaceに紐付いたバッファでの`create`/`enter`はどちらも拒否する
- `git worktree`操作の失敗は、既存`infrastructure/worktree/manager.lua`と同様にgitのエラーメッセージをそのまま提示し、独自のリトライや強制実行は行わない

## テスト方針

- `tests/e2e/`に`vibing_workspace_spec.lua`を追加し、以下を検証する
  - `/vibing-workspace-create`でディレクトリ構成・`meta.yaml`・`plan.md`が正しく生成されること
  - 既にworkspaceに紐付いたバッファで`create`/`enter`が拒否されること
  - `/vibing-workspace-done`が未チェックTODOで警告を出すこと、worktree削除後にactiveからdoneへ移動すること
  - `:VibingSetFileTitle`後に`meta.yaml`の`chat_files`が更新されること
