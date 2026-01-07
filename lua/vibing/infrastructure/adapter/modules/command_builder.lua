---@class Vibing.CommandBuilder
---Handles construction of Node.js command-line arguments for the Agent SDK wrapper.
---Combines global config and frontmatter (opts) to build the command array.
local M = {}

---ノード実行可能ファイルのパスを取得
---PATHから検索し、見つからない場合は"node"にフォールバック
---@return string ノード実行可能ファイルのパス
local function get_node_executable()
  local node_cmd = vim.fn.exepath("node")
  if node_cmd == "" then
    node_cmd = "node"
  end
  return node_cmd
end

---モードを決定（opts優先、次にconfig）
---@param opts Vibing.AdapterOpts フロントマターオプション
---@param config Vibing.Config グローバル設定
---@return string? モード（auto, plan, code, explore）
local function resolve_mode(opts, config)
  local mode = opts.mode
  if not mode and config.agent and config.agent.default_mode then
    mode = config.agent.default_mode
  end
  return mode
end

---モデルを決定（opts優先、次にconfig）
---@param opts Vibing.AdapterOpts フロントマターオプション
---@param config Vibing.Config グローバル設定
---@return string? モデル（sonnet, opus, haiku）
local function resolve_model(opts, config)
  local model = opts.model
  if not model and config.agent and config.agent.default_model then
    model = config.agent.default_model
  end
  return model
end

---言語設定を決定（opts優先、次にconfig）
---@param opts Vibing.AdapterOpts フロントマターオプション
---@param config Vibing.Config グローバル設定
---@return string? 言語コード（ja, enなど）
local function resolve_language(opts, config)
  local language = opts.language
  if not language and config.language then
    if type(config.language) == "table" then
      -- For title generation (and other non-chat/inline uses), use default
      language = config.language.default or config.language.chat
    else
      language = config.language
    end
  end
  if language and type(language) == "string" then
    return language
  end
  return nil
end

---コンテキストファイルパスをコマンド引数に追加
---@param cmd string[] コマンド配列
---@param opts Vibing.AdapterOpts フロントマターオプション
local function add_context_args(cmd, opts)
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      local path = ctx:sub(7)
      table.insert(cmd, "--context")
      table.insert(cmd, path)
    end
  end
end

---パーミッション関連の引数を追加
---フロントマターの設定を使用（configは新規チャット作成時のテンプレートとしてのみ使用）
---@param cmd string[] コマンド配列
---@param opts Vibing.AdapterOpts フロントマターオプション
local function add_permission_args(cmd, opts)
  -- Allow tools (always include MCP tools for vibing.nvim integration)
  local allow_tools = opts.permissions_allow
  if allow_tools then
    allow_tools = vim.deepcopy(allow_tools)
  else
    allow_tools = {}
  end
  table.insert(allow_tools, "mcp__vibing-nvim__*")

  if #allow_tools > 0 then
    table.insert(cmd, "--allow")
    table.insert(cmd, table.concat(allow_tools, ","))
  end

  -- Deny tools
  local deny_tools = opts.permissions_deny
  if deny_tools and #deny_tools > 0 then
    table.insert(cmd, "--deny")
    table.insert(cmd, table.concat(deny_tools, ","))
  end

  -- Ask tools
  local ask_tools = opts.permissions_ask
  if ask_tools and #ask_tools > 0 then
    table.insert(cmd, "--ask")
    table.insert(cmd, table.concat(ask_tools, ","))
  end

  -- Permission mode
  local permission_mode = opts.permission_mode
  if permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, permission_mode)
  end
end

---パーミッションルールを追加（configから取得）
---@param cmd string[] コマンド配列
---@param config Vibing.Config グローバル設定
local function add_permission_rules(cmd, config)
  local rules = config.permissions and config.permissions.rules
  if rules and #rules > 0 then
    table.insert(cmd, "--rules")
    table.insert(cmd, vim.json.encode(rules))
  end
end

---追加フラグを追加（prioritize_vibing_lsp, mcp_enabled, tool_result_display）
---@param cmd string[] コマンド配列
---@param config Vibing.Config グローバル設定
local function add_additional_flags(cmd, config)
  -- Prioritize vibing LSP
  local prioritize_vibing_lsp = config.agent and config.agent.prioritize_vibing_lsp
  if prioritize_vibing_lsp ~= nil then
    table.insert(cmd, "--prioritize-vibing-lsp")
    table.insert(cmd, tostring(prioritize_vibing_lsp))
  end

  -- MCP enabled
  local mcp_enabled = config.mcp and config.mcp.enabled
  if mcp_enabled ~= nil then
    table.insert(cmd, "--mcp-enabled")
    table.insert(cmd, tostring(mcp_enabled))
  end

  -- Tool result display
  local tool_result_display = config.ui and config.ui.tool_result_display
  if tool_result_display then
    table.insert(cmd, "--tool-result-display")
    table.insert(cmd, tool_result_display)
  end
end

---RPCポートを取得して引数に追加
---@param cmd string[] コマンド配列
local function add_rpc_port(cmd)
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    table.insert(cmd, "--rpc-port")
    table.insert(cmd, tostring(rpc_port))
  end
end

---コマンドライン引数を構築
---Node.jsラッパースクリプトの実行コマンドを生成
---mode, model, context, session, permissionsを設定から反映
---opts内の値はfrontmatterから渡され、グローバル設定より優先される
---@param wrapper_path string ラッパースクリプトの絶対パス
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキストファイル等のオプション
---@param session_id string? セッションID（nilの場合は新規セッション）
---@param config Vibing.Config グローバル設定
---@return string[] コマンドと引数の配列（最初の要素がNode実行可能ファイル、続いてラッパーパスとフラグ）
function M.build(wrapper_path, prompt, opts, session_id, config)
  local cmd = { get_node_executable(), wrapper_path }

  -- Working directory
  table.insert(cmd, "--cwd")
  table.insert(cmd, vim.fn.getcwd())

  -- Mode
  local mode = resolve_mode(opts, config)
  if mode then
    table.insert(cmd, "--mode")
    table.insert(cmd, mode)
  end

  -- Model
  local model = resolve_model(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  -- Context files
  add_context_args(cmd, opts)

  -- Session ID for resuming
  if session_id then
    table.insert(cmd, "--session")
    table.insert(cmd, session_id)
  end

  -- Permissions
  add_permission_args(cmd, opts)
  add_permission_rules(cmd, config)

  -- Additional flags
  add_additional_flags(cmd, config)

  -- Language
  local language = resolve_language(opts, config)
  if language then
    table.insert(cmd, "--language")
    table.insert(cmd, language)
  end

  -- RPC port
  add_rpc_port(cmd)

  -- Prompt (always last)
  table.insert(cmd, "--prompt")
  table.insert(cmd, prompt)

  return cmd
end

return M
