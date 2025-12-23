---@class Vibing.Config
---vibing.nvimプラグインの設定オブジェクト
---Agent SDK設定、チャットウィンドウ、キーマップ、ツール権限、リモート制御を統合管理
---@field agent Vibing.AgentConfig Agent SDK設定（モード、モデル）
---@field chat Vibing.ChatConfig チャットウィンドウ設定（位置、サイズ、自動コンテキスト、保存先）
---@field keymaps Vibing.KeymapConfig キーマップ設定（送信、キャンセル、コンテキスト追加）
---@field permissions Vibing.PermissionsConfig ツール権限設定（許可/拒否リスト）
---@field remote Vibing.RemoteConfig リモート制御設定（ソケットパス、自動検出）
---@field mcp Vibing.McpConfig MCP統合設定（RPCポート、自動起動）
---@field language? string|Vibing.LanguageConfig AI応答のデフォルト言語（"ja", "en"等、またはLanguageConfig）

---@class Vibing.PermissionRule
---粒度の細かい権限制御ルール
---ツール入力パラメータに基づいて許可/拒否を制御
---@field tools string[] 対象ツール名のリスト（例: {"Read", "Write"}）
---@field paths string[]? ファイルパスのglobパターンリスト（例: {"src/**", "tests/**"}）
---@field commands string[]? Bashコマンド名のリスト（例: {"npm", "yarn"}）
---@field patterns string[]? Bashコマンドパターン（正規表現）のリスト（例: {"^rm -rf", "^sudo"}）
---@field domains string[]? 許可/拒否するドメインリスト（例: {"github.com", "*.example.com"}）
---@field action "allow"|"deny" ルールのアクション（"allow": 許可、"deny": 拒否）
---@field message string? 拒否時のメッセージ（actionが"deny"の場合に表示）

---@class Vibing.PermissionsConfig
---ツール権限設定
---Agent SDKに対してClaudeが使用可能なツールを制御（Read, Edit, Write, Bash等）
---allowで許可、denyで拒否し、セキュリティと機能のバランスを調整
---@field mode "default"|"acceptEdits"|"bypassPermissions" 権限モード（"default": 毎回確認、"acceptEdits": 編集自動許可、"bypassPermissions": 全自動許可）
---@field allow string[] 許可するツールリスト（例: {"Read", "Edit", "Write"}）
---@field deny string[] 拒否するツールリスト（例: {"Bash"}、危険なツールを明示的に禁止）
---@field rules Vibing.PermissionRule[]? 粒度の細かい権限制御ルール（オプション）

---@class Vibing.AgentConfig
---Agent SDK設定
---Claudeのモード（code/plan/explore）とモデル（sonnet/opus/haiku）を指定
---@field default_mode "code"|"plan"|"explore" デフォルトモード（"code": コード生成、"plan": 計画、"explore": 探索）
---@field default_model "sonnet"|"opus"|"haiku" デフォルトモデル（"sonnet": バランス、"opus": 高性能、"haiku": 高速）

---@class Vibing.RemoteConfig
---リモート制御設定
---nvim --listen で起動されたNeovimインスタンスを別ウィンドウから制御する設定
---@field socket_path string? ソケットパス（明示的に指定、nilの場合は$NVIM環境変数を使用）
---@field auto_detect boolean 環境変数からソケットパスを自動検出するか（trueで$NVIMから自動取得）

---@class Vibing.McpConfig
---MCP統合設定
---Neovim RPC ServerとMCPサーバーの連携を制御
---@field enabled boolean MCP統合の有効化（trueでRPCサーバーを起動）
---@field rpc_port number RPCサーバーのポート番号（デフォルト: 9876）
---@field auto_setup boolean プラグインインストール時に自動セットアップ（MCPビルド）を実行
---@field auto_configure_claude_json boolean ~/.claude.jsonを自動的に設定（要auto_setup）

---@class Vibing.ChatConfig
---チャット機能設定
---ウィンドウ位置・サイズ、自動コンテキスト、保存先、コンテキスト挿入位置を管理
---@field window Vibing.WindowConfig ウィンドウ表示設定（位置、幅、枠線）
---@field auto_context boolean 自動コンテキスト有効化（trueで開いているバッファを自動的にコンテキストに含める）
---@field save_location_type "project"|"user"|"custom" 保存先タイプ（"project": プロジェクト内、"user": ユーザーディレクトリ、"custom": カスタムパス）
---@field save_dir string カスタム保存先ディレクトリ（save_location_type="custom"時に使用）
---@field context_position "prepend"|"append" コンテキスト挿入位置（"prepend": プロンプト前、"append": プロンプト後）

---@class Vibing.WindowConfig
---チャットウィンドウ表示設定
---位置、幅、枠線スタイルを制御
---@field position "right"|"left"|"float" ウィンドウ位置（"right": 右分割、"left": 左分割、"float": フローティング）
---@field width number ウィンドウ幅（0-1の小数で画面比率、1以上で絶対幅）
---@field border string 枠線スタイル（"rounded", "single", "double", "none"等）

---@class Vibing.KeymapConfig
---キーマップ設定
---チャットバッファ内での操作キーを定義
---@field send string メッセージ送信キー（デフォルト: "<CR>"）
---@field cancel string 実行キャンセルキー（デフォルト: "<C-c>"）
---@field add_context string コンテキスト追加キー（デフォルト: "<C-a>"）
---@field open_diff string ファイルパス上でdiff表示キー（デフォルト: "gd"）
---@field open_file string ファイルパス上でファイルを開くキー（デフォルト: "gf"）

---@class Vibing.LanguageConfig
---言語設定（詳細）
---chat と inline で異なる言語を指定可能
---@field default? string デフォルト言語（"ja", "en", "zh", "ko", "fr", "de", "es"等）
---@field chat? string chatアクションでの言語（指定されていない場合はdefaultを使用）
---@field inline? string inlineアクションでの言語（指定されていない場合はdefaultを使用）

local notify = require("vibing.utils.notify")
local tools_const = require("vibing.constants.tools")
local language_utils = require("vibing.utils.language")

local M = {}

---@type Vibing.Config
M.defaults = {
  agent = {
    default_mode = "code",  -- "code" | "plan" | "explore"
    default_model = "sonnet",  -- "sonnet" | "opus" | "haiku"
  },
  chat = {
    window = {
      position = "current",  -- "current" | "right" | "left" | "float"
      width = 0.4,
      border = "rounded",
    },
    auto_context = true,
    save_location_type = "project",  -- "project" | "user" | "custom"
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",  -- Used when save_location_type is "custom"
    context_position = "append",  -- "prepend" | "append"
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
  },
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = {
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
    },
    deny = {
      "Bash",
    },
    rules = {},  -- Granular permission rules (optional)
  },
  remote = {
    socket_path = nil,  -- Auto-detect from NVIM env variable
    auto_detect = true,
  },
  mcp = {
    enabled = false,  -- MCP integration disabled by default
    rpc_port = 9876,  -- RPC server port
    auto_setup = false,  -- Auto-build MCP server on plugin install
    auto_configure_claude_json = false,  -- Auto-configure ~/.claude.json
  },
  language = nil,  -- No language specification by default (responds in English)
}

---@type Vibing.Config
M.options = {}

---vibing.nvimプラグインの設定を初期化
---ユーザー設定とデフォルト設定をマージし、ツール権限の妥当性を検証
---permissionsで指定されたツール名が有効かチェックし、無効な場合は警告を出力
---@param opts? Vibing.Config ユーザー設定オブジェクト（nilの場合はデフォルト設定のみ使用）
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  if M.options.permissions then
    -- Validate permission mode
    local valid_modes = { default = true, acceptEdits = true, bypassPermissions = true }
    local mode = M.options.permissions.mode
    if mode and not valid_modes[mode] then
      notify.warn(string.format(
        "Invalid permissions.mode '%s'. Valid values: default, acceptEdits, bypassPermissions",
        mode
      ))
    end

    -- Helper: Validate tool name or Bash pattern
    local function is_valid_tool(tool_str)
      -- Check for Bash pattern: Bash(command:*)
      if tool_str:match("^Bash%([^:]+:%*%)$") then
        return true
      end
      -- Check for MCP tool: mcp__server__tool
      if tool_str:match("^mcp__") then
        return true
      end
      -- Check built-in tools
      return tools_const.VALID_TOOLS_MAP[tool_str] ~= nil
    end

    -- Validate tool names
    for _, tool in ipairs(M.options.permissions.allow or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.allow", tool))
      end
    end
    for _, tool in ipairs(M.options.permissions.deny or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.deny", tool))
      end
    end
  end

  -- Validate language configuration
  if M.options.language then
    local function validate_lang_code(code, field_name)
      if code and code ~= "" and code ~= "en" and not language_utils.language_names[code] then
        notify.warn(string.format(
          "Unknown language code '%s' in %s. Supported codes: %s",
          code,
          field_name,
          table.concat(vim.tbl_keys(language_utils.language_names), ", ")
        ))
      end
    end

    if type(M.options.language) == "string" then
      validate_lang_code(M.options.language, "language")
    elseif type(M.options.language) == "table" then
      validate_lang_code(M.options.language.default, "language.default")
      validate_lang_code(M.options.language.chat, "language.chat")
      validate_lang_code(M.options.language.inline, "language.inline")
    end
  end

  -- Directory creation is handled by chat_buffer.lua _get_save_directory()
end

---現在の設定を取得
---setup()で初期化された設定オブジェクトを返す
---setup()が未実行の場合は空のテーブルを返す
---@return Vibing.Config 現在の設定オブジェクト
function M.get()
  return M.options
end

return M
