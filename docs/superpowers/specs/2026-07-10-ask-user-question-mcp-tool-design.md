# vibing.nvim専用 ask_user_question ツール 設計

## 背景

vibing.nvimは`claude -p --output-format stream-json`（ヘッドレス／非対話モード）で`claude` CLIを起動している（`lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`）。ネイティブの`AskUserQuestion`ツールは対話的なターミナルUIを前提とした機能であり、このヘッドレスモードではツール一覧に含まれないことが確認された（Claude Code CLI側の内部実装によるもので、vibing.nvim側では制御できない）。

その結果、モデルがユーザーに選択肢付きの質問をしたい場面でも`AskUserQuestion`を呼べず、フリーテキストでの質問に頼らざるを得ない、または全く聞かずに進めてしまうことがある。

既存の`lua/vibing/infrastructure/rpc/handlers/permission.lua`には、`AskUserQuestion`が呼ばれた場合に横取りしてチャットバッファへ選択肢UIとして挿入する仕組み（`cancel_and_deny` + `on_insert_choices`）が既にあるが、そもそもツールが呼ばれること自体が構造的に起こらないため機能していない。

## 方針

vibing.nvim専用の代替ツールを、既存の`vibing-nvim` MCPサーバー（`mcp-server/`）に追加する。ツール自体は「宣言だけ」で、実行は既存の`AskUserQuestion`横取りと全く同じ経路（PreToolUseフック→`permission.lua`→deny+`insert_choices`イベント→チャットバッファへのテキストUI挿入）を再利用する。これにより:

- ヘッドレスモードでも確実に選択肢UIを提示できる
- 既存のUX（Vimの`dd`等で選択肢を編集して送信）を完全に維持する
- 新しいブロッキング処理やRPC往復を増やさない（安定した既存パターンの再利用）

## 変更点

### 1. `mcp-server/src/tools/chat.ts` — ツール定義追加

`nvim_ask_user_question`という名前で追加。入力スキーマは既存の`AskUserQuestion`と同一の形（`questions: [{question, multiSelect?, options: [{label, description?}]}]`）とし、`lua/vibing/presentation/chat/modules/renderer.lua`の既存レンダリングロジックをそのまま利用できるようにする。

### 2. `mcp-server/src/handlers/chat.ts` — ハンドラ追加（防御的フォールバック）

このツールは通常、PreToolUseフックによって実行前に必ず横取り・denyされる。ハンドラ本体が呼ばれるのはフックが何らかの理由で機能しなかった異常系のみなので、単にエラーメッセージを返すだけの実装とする。

### 3. `lua/vibing/infrastructure/rpc/handlers/permission.lua` — 横取り処理追加

`check_tool_permission`内で、`tool_name == "mcp__vibing-nvim__nvim_ask_user_question"`かつ`perm_config.mcp_enabled == true`の場合に、既存の`AskUserQuestion`と同じ`cancel_and_deny` + `on_insert_choices`経路へ流す。`mcp_enabled == false`の場合は通常の`can_use_tool`経由のdeny（「vibing.nvim MCP integration is disabled」メッセージ）にフォールバックする——ユーザーがMCP統合自体を無効化している場合の意図を尊重するため。

### 4. `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` — システムプロンプト誘導

既存のworktree規約行と同じ場所（`system_prompt_lines`）に、「選択肢付きの質問をしたい場合は必ず`mcp__vibing-nvim__nvim_ask_user_question`ツールを使うこと」という一文を無条件で追記する。これにより、モデルがネイティブの`AskUserQuestion`やフリーテキストに頼らず、確実にこの新ツールを使うよう誘導する。

## 影響範囲外

- `codex_cli.lua`（Codexアダプター）は対象外。Codexには同種のシステムプロンプト注入機構がなく、`AskUserQuestion`相当の概念も持たないため。
- 既存の`AskUserQuestion`横取りコード自体は削除しない（無害なフォールバックとして残す）。

## テスト方針

- `tests/`配下のLua仕様（`permission`関連の既存スペックがあれば拡張、なければ新規）で、新ツール名が`AskUserQuestion`と同じ経路に流れることを検証する。
- `mcp-server/`側のTypeScriptテスト（既存の`chat.ts`ハンドラのテストパターンに準拠）でツール定義とハンドラのフォールバック応答を検証する。
