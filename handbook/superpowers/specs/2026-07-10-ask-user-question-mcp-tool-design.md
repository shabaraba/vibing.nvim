# vibing.nvim専用 ask_user_question ツール 設計

> **現在の設計は「再改訂: handle_idをツール引数として渡す設計に変更」章以降**。それより前の章は採用されなかった過去案で、変更の経緯を残すために残置している。

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

## 再改訂: handle_idをツール引数として渡す設計に変更

### 発覚した不具合

「改訂」章の設計（`M.ask_user_question`がハンドラから直接呼ばれる方式）には、実運用で`nvim_ask_user_question`呼び出し後もモデルのターンがキャンセルされず、そのまま会話が続いてしまう不具合があった。

原因は`process.env.VIBING_HANDLE_ID`がMCPサーバーの子プロセスに構造的に届かないこと。`@modelcontextprotocol/sdk`の`StdioClientTransport`は子プロセスのenvを常に

```js
env: { ...getDefaultEnvironment(), ...this._serverParams.env }
```

として構築する（`mcp-server/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js`）。`getDefaultEnvironment()`はUnix環境で`HOME, LOGNAME, PATH, SHELL, TERM, USER`のみを継承する固定ホワイトリストであり、`VIBING_HANDLE_ID`のような独自変数は含まれない。また`serverParams.env`は`.claude-plugin/plugin.json`に書かれた**静的なJSON**であり、`stream()`呼び出しごとに変わる動的な`handle_id`をそこへ反映する手段もない。

結果として`handleAskUserQuestion`が読む`process.env.VIBING_HANDLE_ID`は常に`undefined`となり、`ActiveStreamRegistry.get(nil)`は「アクティブなストリームがちょうど1つの場合のみ推測」というフォールバックに頼る。複数チャットが同時に走っている（あるいは0件になっている）タイミングでは`nil`が返り、`M.ask_user_question`はプロセスをキルせずにエラーの`tool_result`を返すだけになる。モデルはそれを普通の拒否として受け取り、会話を継続してしまう。

「改訂」章で「`handle_id`はモデルに引数として渡させない——モデルがこの値を知る正当な手段がないため」としていたが、システムプロンプトへ埋め込めばモデルに正当な手段を与えられる。

### 変更点（再改訂）

1. `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` — `M.build`に`handle_id`引数を追加。渡されていれば「`mcp__vibing-nvim__nvim_ask_user_question`を呼ぶときは必ずこの`handle_id`を引数として渡すこと」という一文と実際の値をシステムプロンプトへ埋め込む。
2. `lua/vibing/infrastructure/adapter/claude_cli.lua` — `stream()`内で生成済みの`handle_id`を`CLICommandBuilder.build`に渡す。
3. `mcp-server/src/tools/chat.ts` — `nvim_ask_user_question`の入力スキーマに`handle_id`（string, required）を追加。
4. `mcp-server/src/handlers/chat.ts` — `handleAskUserQuestion`が`process.env.VIBING_HANDLE_ID`ではなくツール引数の`handle_id`を読むように変更。Zodスキーマで必須化し、渡し忘れは（サイレントに推測へ劣化するのではなく）呼び出し自体のバリデーションエラーとして顕在化させる。
5. `lua/vibing/infrastructure/rpc/handlers/permission.lua`の`M.ask_user_question`・`ActiveStreamRegistry`は変更なし（引数の出所が変わるだけで、受け取り方は同じ）。

### 影響範囲外（変更なし）

- `codex_cli.lua` / `codex_command_builder.lua`はそもそも`nvim_ask_user_question`を使うシステムプロンプト指示を持たないため対象外。
- ネイティブ`AskUserQuestion`の横取りコード（PreToolUseフック経由）は無関係のため変更なし。

## 追記: rpc_portにも同じ問題が見つかり、同じ手法で修正

`handle_id`修正の検証中、`.claude-plugin/plugin.json`が`VIBING_RPC_PORT`を`9876`に**固定**していることが判明した。複数のNeovimインスタンス（≒複数プロジェクト）が同時に起動している環境では、MCPサーバーは常に「たまたまポート9876を掴んでいる、無関係なインスタンス」に話しかけてしまう——`handle_id`と全く同根の構造的問題（MCPサーバーのenvは`getDefaultEnvironment()`の固定ホワイトリストと静的JSONの合成でしか決まらない）。

この問題は`nvim_ask_user_question`に限らず、`rpc_port`を受け取る全てのvibing-nvim MCPツール（`nvim_get_buffer`等、ほぼ全ツール）に共通する。修正方針も同一：

1. `mcp-server/src/tools/common.ts` — `rpcPortProperty`の説明文を更新。全ツールの`required`に`rpc_port`を含める`requireRpcPort()`ヘルパーを追加。
2. `mcp-server/src/tools/{buffer,cursor,execute,lsp,window,chat}.ts` — 全ツール定義の`required`に`rpc_port`を追加（`nvim_list_instances`は登録済みインスタンス一覧をファイルベースのレジストリから読むだけで特定のNeovimインスタンスに接続しないため対象外）。
3. `mcp-server/src/handlers/chat.ts` — `rpc_port`のZodスキーマを`z.number().optional()`から`z.number()`（必須）に変更。
4. `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` — `M.build`に`rpc_port`引数を追加し、渡されていれば実際の値とともに「`mcp__vibing-nvim__*`を呼ぶときは必ずこの`rpc_port`を引数として渡すこと」という一文をシステムプロンプトへ埋め込む。
5. `lua/vibing/infrastructure/adapter/claude_cli.lua` — `rpc_port`の算出（`rpc_server.get_port()`）を`CLICommandBuilder.build`呼び出しより前に移動し、そこへ渡す。

`handle_id`と同様、「渡し忘れたら黙って推測する」のではなく「渡し忘れたら呼び出し自体が失敗する」設計とした。

## 追記: 非プラグイン経路のMCPサーバー登録を廃止

上記2つの根本原因はどちらも「MCPサーバーのenvは静的JSONでしか渡せない」という同じ制約に起因する。この制約は`.claude-plugin/plugin.json`（Claude Codeプラグイン経由の登録）でも`bin/register-mcp.ts`（`~/.claude.json`への直接登録、`register-mcp.ts`は削除済み）でも同じだが、後者は登録経路が二重になるだけで対処にならないため、vibing-nvim MCPサーバーの登録はプラグイン経由に一本化した。

- `bin/register-mcp.ts`を削除。
- `build.sh`から`register_mcp_json_fallback`（`~/.claude.json`への直接書き込みフォールバック）を削除。`claude`CLIまたは`claude plugin install`が失敗した場合は、手動コマンドを案内するのみ。
- `lua/vibing/mcp/setup.lua`を削除（`setup_claude_json`/`auto_setup`/`setup_wizard`など、すべて`~/.claude.json`への直接書き込みを前提とした機能だったため）。
- `lua/vibing/install.lua`から`dist/bin/register-mcp.js`呼び出しを削除し、`claude plugin install`の案内メッセージに置き換え。
- `lua/vibing/config.lua`から`mcp.auto_setup`・`mcp.auto_configure_claude_json`を削除。
- `lua/vibing/init.lua`から対応する自動セットアップ呼び出しを削除。
