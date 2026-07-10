# vibing.nvim専用 ask_user_question ツール 設計

## 背景

vibing.nvimは`claude -p --output-format stream-json`（ヘッドレス／非対話モード）で`claude` CLIを起動している（`lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`）。ネイティブの`AskUserQuestion`ツールは対話的なターミナルUIを前提とした機能であり、このヘッドレスモードではツール一覧に含まれないことが確認された（Claude Code CLI側の内部実装によるもので、vibing.nvim側では制御できない）。

その結果、モデルがユーザーに選択肢付きの質問をしたい場面でも`AskUserQuestion`を呼べず、フリーテキストでの質問に頼らざるを得ない、または全く聞かずに進めてしまうことがある。

既存の`lua/vibing/infrastructure/rpc/handlers/permission.lua`には、`AskUserQuestion`が呼ばれた場合に横取りしてチャットバッファへ選択肢UIとして挿入する仕組み（`cancel_and_deny` + `on_insert_choices`）が既にあるが、そもそもツールが呼ばれること自体が構造的に起こらないため機能していない。

## 方針（初版）

vibing.nvim専用の代替ツールを、既存の`vibing-nvim` MCPサーバー（`mcp-server/`）に追加する。ツール自体は「宣言だけ」で、実行は既存の`AskUserQuestion`横取りと全く同じ経路（PreToolUseフック→`permission.lua`→deny+`insert_choices`イベント→チャットバッファへのテキストUI挿入）を再利用する。これにより:

- ヘッドレスモードでも確実に選択肢UIを提示できる
- 既存のUX（Vimの`dd`等で選択肢を編集して送信）を完全に維持する
- 新しいブロッキング処理やRPC往復を増やさない（安定した既存パターンの再利用）

### 変更点（初版）

1. `mcp-server/src/tools/chat.ts` — `nvim_ask_user_question`という名前でツール定義を追加。入力スキーマは既存の`AskUserQuestion`と同一の形（`questions: [{question, multiSelect?, options: [{label, description?}]}]`）とし、`lua/vibing/presentation/chat/modules/renderer.lua`の既存レンダリングロジックをそのまま利用できるようにする。
2. `mcp-server/src/handlers/chat.ts` — ハンドラは防御的フォールバックのみ（単にエラーメッセージを返す）。通常はPreToolUseフックが実行前に必ず横取り・denyするため、ハンドラ本体は呼ばれない想定。
3. `lua/vibing/infrastructure/rpc/handlers/permission.lua` — `check_tool_permission`内で、`tool_name`がvibing-nvim MCPツール名にマッチしかつ`perm_config.mcp_enabled == true`の場合に、既存の`AskUserQuestion`と同じ`cancel_and_deny` + `on_insert_choices`経路へ流す。
4. `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` — システムプロンプトに「選択肢付きの質問をしたい場合は必ず`mcp__vibing-nvim__nvim_ask_user_question`ツールを使うこと」という一文を追記。

## 改訂: ハンドラ自身が横取り処理を行う設計に変更

初版はネイティブ`AskUserQuestion`の横取りコードをそのまま流用していたが、ネイティブツールと違いこのMCPツールは実行を完全に制御できる自作ツールであり、「PreToolUseフックがツール名でマッチして横取り・deny→ハンドラ本体は永久にデッドコード」という構造は不必要に遠回りだった。ツール本来の`tool_use → tool_result`の形にはならない（後述の通りキャンセルにより結果は返らない）ものの、**キャンセル処理と選択肢UI挿入というツールの実際の振る舞いは、ハンドラ自身が直接行う**よう変更した。

### 変更点（改訂）

1. `lua/vibing/infrastructure/rpc/handlers/permission.lua`
   - `check_tool_permission`の`is_ask_user_question_tool`判定から、`nvim_ask_user_question`（vibing-nvim MCPツール）向けの分岐を削除。ネイティブ`AskUserQuestion`用の分岐のみ残す（あちらは実行を制御できないためhook横取りが唯一の手段）。
   - 新規RPCメソッド`M.ask_user_question(params)`を追加。`params = {handle_id, questions}`を受け取り、`ActiveStreamRegistry.get(handle_id)`でstreamを特定し、`stream.adapter:cancel(...)` → `stream.on_insert_choices(questions)`を直接実行する。hookのファイルベースreq/res（`.req`/`.res`）は経由しない——このRPC呼び出し自体がフックの代わりであり、応答を書き戻す相手（`pre-tool-use.sh`）が存在しないため。
2. `lua/vibing/infrastructure/rpc/handlers/init.lua` — `M.ask_user_question = permission.ask_user_question`を登録。
3. `mcp-server/src/handlers/chat.ts` — `handleAskUserQuestion`を実装。`process.env.VIBING_HANDLE_ID`（`claude`本体プロセスに設定され、MCPサーバーの子プロセスへ継承される値）と、ツール引数の`questions`・任意の`rpc_port`を使って`callNeovim('ask_user_question', {...})`を呼ぶ。**`handle_id`はモデルに引数として渡させない**——モデルがこの値を知る正当な手段がないため（`rpc_port`とは異なり、`nvim_list_instances`のような発見手段もない）。
4. `mcp-server/src/tools/chat.ts` — ツールのdescriptionに、呼び出すと即座にターン全体がキャンセル/killされ、通常の`tool_result`は返らないこと、次回呼び出し時のプロンプトがユーザーの回答そのものであることを明記。モデルが「結果を待つ」という誤った期待を持たないようにするため。

### 影響範囲外（変更なし）

- `codex_cli.lua`（Codexアダプター）は対象外。
- ネイティブ`AskUserQuestion`の横取りコード自体は削除しない（無害なフォールバックとして残す）。

## テスト方針

- `mcp-server/src/__tests__/chat-tools.test.ts` — `callNeovim`をモックし、`nvim_ask_user_question`ハンドラが`ask_user_question` RPCを`{handle_id, questions}`付きで呼ぶこと、RPCが`status: "error"`を返した場合に`isError: true`で返すことを検証。
- 既存の`tests/e2e/nvim_ask_user_question_spec.lua`（選択肢UIが1回だけ描画されることを検証するE2E）は実装経路が変わっても外部から見た挙動は同一のため、変更なしでそのまま通る想定。
