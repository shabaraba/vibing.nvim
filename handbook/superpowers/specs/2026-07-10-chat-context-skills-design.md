# vibing.nvim: チャットコンテキスト回復・検索スキル設計

## 背景・目的

vibing.nvim でセッションが切れる、あるいはコンテキストウィンドウの都合で文脈が失われることがある。
また、過去にどのチャットで何を聞いたか思い出せずに探すのが手間になっている。

この2つの課題に対応する、vibing.nvim にバンドルされる Claude Code スキル（`skills/` 配下）を2つ追加する。

- `vibing-chat-recall` — 今動いている会話自身のチャットバッファを読み直し、コンテキストを内部的に復元する
- `vibing-chat-search` — `.vibing/chat/` 配下の過去のチャットファイルを自然言語クエリで検索する

両スキルとも、既存の `skills/nvim-context/SKILL.md` 等と同じ形式（frontmatter に `name`/`description` のみ）で追加する。
呼び出し方法は自然言語トリガー・Claude自身の自律判断・スラッシュコマンド（`/<name>`）のすべてに対応する。
これは SKILL.md の `name` フィールドがそのまま `/<name>` として使えるという、通常のスキル呼び出し規約に従うだけで満たされる。

## 前提調査で分かったこと

- vibing.nvim のチャットバッファは **自動保存されない**。`:w` 等の明示的な保存操作がない限り、ディスク上のファイルは
  会話の最新状態を反映していない。したがって「今の会話の内容を読み直す」には、ディスクファイルではなく
  **生きている Neovim バッファ**（`mcp__vibing-nvim__nvim_get_buffer`）を読む必要がある。
- 現状、Claude Code プロセスに対して「どのチャットファイルからの依頼か」を伝える手段が存在しない
  （`VIBING_NVIM_RPC_PORT` 等の環境変数はあるが、チャットファイルパスは渡っていない）。
  Neovimウィンドウのフォーカスに依存する方法は、フォーカスが外れていたり複数チャットが並行実行されている場合に
  取り違えるため使わない。確実に特定するには、送信元のチャットバッファのファイルパスを Claude CLI 起動時に
  システムプロンプトへ埋め込む、コア側の小さな変更が必要。
- Codex アダプター（`codex_command_builder.lua`）には同種のシステムプロンプト注入の仕組みがそもそも存在せず、
  SKILL.md 形式のスキル自体が Claude Code 固有の機能であるため、コア変更は Claude CLI アダプター側のみで良い。

## コア変更（両スキルの前提となる基盤）

### 1. `lua/vibing/application/chat/send_message.lua`

`do_send` 内、`opts` テーブル構築時に、送信元チャットバッファの絶対パスを渡す一行を追加する。

```lua
chat_file_path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or nil,
```

### 2. `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`

`system_prompt_lines` に、既存の worktree 規約行と同じ場所へ以下を追加する。

```lua
if opts.chat_file_path and opts.chat_file_path ~= "" then
  table.insert(system_prompt_lines, "Current vibing.nvim chat buffer file: " .. opts.chat_file_path)
end
```

既存の worktree 規約行が全リクエストに無条件で追記されているのと同じパターンであり、
スキルを使わない通常のチャットには一切影響しない（Claude が読み飛ばすだけの一行が増えるのみ）。

## スキル1: `vibing-chat-recall`

**配置**: `skills/vibing-chat-recall/SKILL.md`

**発動条件**（frontmatter description に明記）:

- ユーザーが「思い出して」「チャット履歴を読み直して」等、自然言語で明示的に要求したとき
- Claude自身が、直前までの会話の流れと噛み合わない応答をしてしまいそうだと判断したとき（セッション切れ・コンテキスト消失の兆候）
- `/vibing-chat-recall` スラッシュコマンドで明示的に呼び出されたとき

**手順**:

1. システムプロンプト中の `Current vibing.nvim chat buffer file: <path>` からファイルパスを取得する。
   見つからない場合（vibing.nvim 外で使われた、またはコア変更が反映されていない古いバージョン）は、
   その旨を一言伝えてスキルを終了する。
2. `mcp__vibing-nvim__nvim_load_buffer(filepath=<path>)` を呼び、バッファ番号を取得する
   （ウィンドウ表示やフォーカス移動なしで裏読み込みできる）。
3. `mcp__vibing-nvim__nvim_get_buffer(bufnr=<bufnr>)` で、生きているバッファの全内容を取得する
   （ディスクに未反映の編集も含めて最新の会話状態を得られる）。
4. 上記 MCP 呼び出しが失敗した場合（RPC 未接続など）は、同じパスを対象に通常の `Read` ツールで
   ディスク上のファイルを読むフォールバックを行う。この場合、直近の未保存分が欠ける可能性があることを
   意識するが、ユーザーへの応答自体は変えない。
5. 取得した内容を読み込み、内部的に文脈を復元する。**ユーザーへの応答は「思い出しました」程度の
   一言のみ**とし、要約や次のアクション提案は行わない。

## スキル2: `vibing-chat-search`

**配置**: `skills/vibing-chat-search/SKILL.md`

**発動条件**（frontmatter description に明記）:

- ユーザーが「前に〜について聞いたことあったっけ」「過去のチャットで〜」等、自然言語で過去のチャット内容を
  探したいとき
- Claude自身が、過去に類似の話題を扱った可能性があると判断したとき
- `/vibing-chat-search` スラッシュコマンドで明示的に呼び出されたとき

**手順**:

1. 検索対象ディレクトリを特定する。git ルートからの相対で `.vibing/chat/` を解決し、存在しなければ
   現在の作業ディレクトリ基準にフォールバックする。
2. ユーザーの自然言語クエリから、grep 用のキーワード候補（同義語・言い換えを含め2〜4個程度）を組み立てる。
3. `Grep` ツールで `.vibing/chat/` 配下の全チャットファイル（`.md` / `.vibing` 拡張子いずれも対象）を
   キーワードで OR 検索し、候補ファイルを絞り込む。**User セクション・Assistant セクションの両方を
   検索対象とする**（ユーザーの言い回しが曖昧でも、Assistant の返答内容にキーワードがあれば拾えるようにするため）。
4. 候補が多すぎる場合（目安15件超）は、マッチ数の多い順に絞り込むか、キーワードをより具体的に
   組み立て直す。
5. 絞り込んだ候補ファイルを実際に読み、ユーザーの意図とのセマンティックな関連度を判断する
   （キーワードが一致しているだけで無関係なものは除外する）。
6. 最終的に該当したチャットファイルごとに、以下を一覧で提示する。要約や次のアクション提案は行わず、
   一覧を出すのみとし、開くかどうかはユーザー任せとする。
   - ファイルパス
   - 日時（frontmatter の `created_at`、なければファイル名から推定）
   - 該当箇所の簡単な要約（1〜2行程度）
7. ヒットが1件もない場合は、無理にこじつけず「見つかりませんでした」と正直に伝える。

## テスト方針

- コア変更（`chat_file_path` の伝搬）は、既存の Lua ユニットテスト（`tests/*_spec.lua`）に
  `cli_command_builder` のシステムプロンプト構築を検証するケースを追加する形で検証する。
- スキル自体（SKILL.md）はプロンプトベースであり自動テスト対象ではないため、実際に vibing.nvim の
  チャットから両スキルを手動で呼び出し、想定通りに動作するかを確認する。

## スコープ外

- Codex アダプターへの同種の変更（対象外。SKILL.md は Claude Code 固有機能のため）。
- `vibing-chat-search` の結果からチャットを直接開く機能（今回は一覧表示のみ。ユーザーの判断は A のみを選択）。
- ベクトル検索・埋め込みベースの意味検索基盤の導入（grep による絞り込み＋Claudeの読解で十分と判断）。
