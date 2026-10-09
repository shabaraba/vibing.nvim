---@class Vibing.Types
---共通型定義モジュール

---@class Vibing.Message
---@field role "user"|"assistant"|"system"
---@field content string
---@field timestamp string?

---@class Vibing.Session
---@field id string?
---@field created_at string
---@field updated_at string?
---@field mode string?
---@field model string?

---@class Vibing.ContextItem
---@field type "file"|"selection"|"buffer"
---@field path string?
---@field content string
---@field start_line number?
---@field end_line number?
---@field bufnr number?

---@class Vibing.Task
---@field id string
---@field execute fun(done: fun())
---@field cancel fun()?

-- Vibing.PermissionRule and Vibing.PermissionsConfig are defined in config.lua

---@class Vibing.AdapterOpts
---@field streaming boolean?
---@field action_type "chat"?
---@field mode string?
---@field model string?
---@field effort ("default"|"low"|"medium"|"high"|"xhigh"|"max")?
---@field profile string? チャットの`profile:` frontmatter。組み込みの`default`/`worker`か`agent.profiles`の名前（`core/constants/profiles.lua`）
---@field process ("oneshot"|"duplex")? チャットの`process:` frontmatter。**要求**であって結果ではない。実際に走るモデルは`adapter/modules/process_model.lua`が決め、`_process_model`に入る
---@field _process_model ("oneshot"|"duplex")? このターンが実際に走るプロセスモデル。`cli_adapter.stream()`が解決して書き込み、`request_builder`の`duplex`条件が読む
---@field tools string[]?
---@field permissions_allow string[]?
---@field permissions_deny string[]?
---@field permissions_ask string[]?
---@field permission_mode string?
---@field exclusive_tools string[]? チャットを持たない裏のエージェントが使えるツールの全部。これ以外はフックが拒否する
---@field env string[]? チャットのfrontmatter `env:` に書かれた`KEY=VALUE`の並び。`agent.env`より優先される（`infrastructure/adapter/modules/agent_environment.lua`）
---@field cwd string? Effective working directory used for project-local configuration
---@field on_tool_use fun(tool: string, file_path: string?)?
---@field on_tool_use_full fun(tool: string, input: table)? 表示用に間引かない生のツール入力（eval用）
---@field on_subagents_orphaned fun(unreported: Vibing.BackgroundTask[], recovered: Vibing.RecoveredSubagent[])? 常駐プロセス（duplex）が回収され、まだ報告していないbackground subagentを連れていった（#840）。**ターンではなくプロセスの寿命に属する唯一のコールバック** — 呼ばれるのはこれを渡したターンの中ではなく、そのプロセスの最後のターンより後
---@field _session_id string?
---@field _session_id_explicit boolean?
---@field lightweight boolean? タイトル生成・要約等の軽量ユーティリティ呼び出し用フラグ。各アダプタは「ツールを使わせない・プロジェクト設定とユーザー MCP サーバーを読ませない・フックを登録しない・utility_model を使う」、かつ「これらが CLI 側のスキーマ変更で黙って外れないこと」を果たす責務を負う（claude は --tools ""、codex は read-only サンドボックス + --ignore-user-config、copilot は --available-tools にダミー名、grok は --tools todo_write + 空のスクラッチ作業ディレクトリ + GROK_*_ENABLED 環境変数）。grok だけは MCP ツールの「提示」を止める手段が CLI 側になく、--deny "MCPTool(*)" で実行のみ拒否している（プロジェクト指示とフックは #588 で塞いだ。詳細は handbook/architecture/lightweight-calls.md）

---@class Vibing.AdapterResponse
---@field content string?
---@field error string?
---@field _turn_id string? このレスポンスが属するターンのID。staleness判定（そのターンをまだ待っているか）はこれで行う
---@field _process_id string? そのターンを走らせたCLIプロセスのID。セッションIDの読み戻しはこれで引く（セッションはプロセスが握っているもの）
---@field _unreported_subagents Vibing.BackgroundTask[]? このターンが起動して完了通知が来なかったバックグラウンドsubagent。**非空なら誰もこのチャットを起こさない**ので、これ自体が起床の合図になる（#820、`application/chat/outstanding_subagents.lua`）
---@field _recovered_subagents Vibing.RecoveredSubagent[]? 上のうち、トランスクリプトから出力を読み出せたもの。起床の判定に使ってはいけない — まだ走っている subagent は答えを書いていないので空になる

-- Vibing.WindowConfig and Vibing.ChatConfig are defined in config.lua

return {}
