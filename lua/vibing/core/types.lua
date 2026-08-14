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
---@field tools string[]?
---@field permissions_allow string[]?
---@field permissions_deny string[]?
---@field permissions_ask string[]?
---@field permission_mode string?
---@field on_tool_use fun(tool: string, file_path: string?)?
---@field on_tool_use_full fun(tool: string, input: table)? 表示用に間引かない生のツール入力（eval用）
---@field _session_id string?
---@field _session_id_explicit boolean?
---@field lightweight boolean? タイトル生成・要約等の軽量ユーティリティ呼び出し用フラグ。各アダプタは「ツールを使わせない・プロジェクト設定とユーザー MCP サーバーを読ませない・フックを登録しない・utility_model を使う」、かつ「これらが CLI 側のスキーマ変更で黙って外れないこと」を果たす責務を負う（claude は --tools ""、codex は read-only サンドボックス + --ignore-user-config、copilot は --available-tools にダミー名、grok は --tools todo_write）。grok だけは CLI 側に手段がなく、プロジェクト指示（AGENTS.md/CLAUDE.md）を読ませないことと MCP ツールの提示を止めることができない（提示は止められないため --deny "MCPTool(*)" で実行のみ拒否している。詳細は architecture.md）

---@class Vibing.AdapterResponse
---@field content string?
---@field error string?
---@field _handle_id string?

-- Vibing.WindowConfig and Vibing.ChatConfig are defined in config.lua

return {}
