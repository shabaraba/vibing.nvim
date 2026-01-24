---@class Vibing.MoteConfig
---mote統合設定
---fine-grainedスナップショット管理ツールmoteとの統合を制御
---@field ignore_file string .moteignoreファイルのパス（デフォルト: ".vibing/.moteignore"）
---@field storage_dir string moteストレージディレクトリのパス（デフォルト: ".vibing/mote"）

---@class Vibing.DiffConfig
---diff表示設定
---ファイル変更のdiff表示に使用するツールを制御
---@field tool "git"|"mote"|"auto" 使用するdiffツール（"git": git diff、"mote": mote diff、"auto": mote優先で自動選択）
---@field mote Vibing.MoteConfig mote固有の設定

---@class Vibing.PreviewConfig
---プレビューUI設定
---インラインアクションとチャットの両方で使用されるdiffプレビューUIを制御
---@field enabled boolean プレビューUI有効化（trueでGit diffプレビュー表示、要Gitリポジトリ）

---@class Vibing.GradientConfig
---グラデーションアニメーション設定
---AI応答中に行番号をグラデーションアニメーションで視覚的にフィードバック
---@field enabled boolean グラデーションアニメーション有効化（trueで応答中に行番号がアニメーション）
---@field colors string[] グラデーション色の配列（2色指定: {開始色, 終了色}、例: {"#cc3300", "#fffe00"}）
---@field interval number アニメーション更新間隔（ミリ秒、デフォルト: 100）

---@class Vibing.ToolMarkersConfig
---ツールマーカー設定
---チャット出力でツール実行時に表示する視覚的マーカーをカスタマイズ
---@field Task? string Taskツール開始マーカー（デフォルト: "▶"）
---@field TaskComplete? string Taskツール完了マーカー（デフォルト: "✓"）
---@field default? string その他のツール用デフォルトマーカー（デフォルト: "⏺"）
---@field [string]? string ツール名をキーとした個別マーカー（例: Read = "📄"）

---@class Vibing.UiConfig
---UI設定
---全UIコンポーネント（Chat、Inline、Output）に適用される表示設定
---@field wrap "nvim"|"on"|"off" 行の折り返し設定（"nvim": Neovimデフォルト、"on": wrap+linebreak有効、"off": wrap無効）
---@field gradient Vibing.GradientConfig グラデーションアニメーション設定（応答中の視覚的フィードバック）
---@field tool_result_display "none"|"compact"|"full" ツール実行結果の表示モード（"none": 非表示、"compact": 数行のみ、"full": 全文表示）
---@field tool_markers? Vibing.ToolMarkersConfig ツールマーカー設定（ツール実行時の視覚的マーカー）

---@class Vibing.Config
---vibing.nvimプラグインの設定オブジェクト
---Agent SDK設定、チャットウィンドウ、キーマップ、ツール権限を統合管理
---@field agent Vibing.AgentConfig Agent SDK設定（モード、モデル）
---@field chat Vibing.ChatConfig チャットウィンドウ設定（位置、サイズ、自動コンテキスト、保存先）
---@field ui Vibing.UiConfig UI設定（wrap等）
---@field keymaps Vibing.KeymapConfig キーマップ設定（送信、キャンセル、コンテキスト追加）
---@field diff Vibing.DiffConfig diff表示設定（使用ツール、mote設定）
---@field preview Vibing.PreviewConfig プレビューUI設定（diffプレビュー有効化）
---@field permissions Vibing.PermissionsConfig ツール権限設定（許可/拒否リスト）
---@field node Vibing.NodeConfig Node.js実行ファイル設定（バイナリパス）
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
---allowで許可、denyで拒否、askで確認を要求し、セキュリティと機能のバランスを調整
---@field mode "default"|"acceptEdits"|"bypassPermissions" 権限モード（"default": 毎回確認、"acceptEdits": 編集自動許可、"bypassPermissions": 全自動許可）
---@field allow string[] 許可するツールリスト（例: {"Read", "Edit", "Write"}）
---@field deny string[] 拒否するツールリスト（例: {"Bash"}、危険なツールを明示的に禁止）
---@field ask string[] 確認が必要なツールリスト（例: {"Bash"}、使用前に承認を要求）
---@field rules Vibing.PermissionRule[]? 粒度の細かい権限制御ルール（オプション）

---@class Vibing.AgentConfig
---Agent SDK設定
---Claudeのモード（code/plan/explore）とモデル（sonnet/opus/haiku）を指定
---@field default_mode "code"|"plan"|"explore" デフォルトモード（"code": コード生成、"plan": 計画、"explore": 探索）
---@field default_model "sonnet"|"opus"|"haiku" デフォルトモデル（"sonnet": バランス、"opus": 高性能、"haiku": 高速）
---@field prioritize_vibing_lsp boolean vibing-nvim LSPツールを優先（true: Serena等の汎用LSPより優先、false: システムプロンプトを挿入しない、デフォルト: true）

---@class Vibing.NodeConfig
---Node.js実行ファイル設定
---Agent SDKラッパーとMCPビルドで使用するNode.js実行ファイルのパスを指定
---@field executable string|"auto" Node.js実行ファイルのパス ("auto": PATHから自動検出、文字列: 明示的なパス指定)
---@field dev_mode boolean 開発モード有効化 (true: TypeScriptを直接bunで実行、false: コンパイル済みJSを使用)

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
---位置、幅、高さ、枠線スタイルを制御
---@field position "right"|"left"|"top"|"bottom"|"back"|"current"|"float" ウィンドウ位置（"right": 右分割、"left": 左分割、"top": 上分割、"bottom": 下分割、"back": バッファのみ作成、"current": 現在のウィンドウ、"float": フローティング）
---@field width number ウィンドウ幅（0-1の小数で画面比率、1以上で絶対幅）
---@field height number ウィンドウ高さ（0-1の小数で画面比率、1以上で絶対高さ、top/bottomで使用）
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

local notify = require("vibing.core.utils.notify")
local tools_const = require("vibing.constants.tools")
local language_utils = require("vibing.core.utils.language")

local M = {}

---@type Vibing.Config
M.defaults = {
  agent = {
    default_mode = "code",
    default_model = "sonnet",
    prioritize_vibing_lsp = true,
  },
  chat = {
    window = {
      position = "current",
      width = 0.4,
      height = 0.4,
      border = "rounded",
    },
    auto_context = true,
    save_location_type = "project",
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
    context_position = "append",
  },
  ui = {
    wrap = "on",
    gradient = {
      enabled = true,
      colors = { "#cc3300", "#fffe00" },
      interval = 100,
    },
    tool_result_display = "compact",
    tool_markers = {
      Task = "▶",
      TaskComplete = "✓",
      default = "⏺",
    },
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
  },
  diff = {
    tool = "auto",
    mote = {
      ignore_file = ".vibing/.moteignore",
      storage_dir = ".vibing/mote",
    },
  },
  preview = {
    enabled = false,
  },
  permissions = {
    mode = "acceptEdits",
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
    ask = {},
    rules = {},
  },
  node = {
    executable = "auto",
    dev_mode = false,
  },
  mcp = {
    enabled = true,
    rpc_port = 9876,
    auto_setup = false,
    auto_configure_claude_json = false,
  },
  language = nil,
}

---@type Vibing.Config
M.options = {}

---Lazy.nvimのdevモードを検出
---vibing.nvimプラグインがLazy.nvimでdev=trueとして設定されているかチェック
---@return boolean Lazy.nvimのdevモードが有効な場合true
local function is_lazy_dev_mode()
  local ok, lazy_config = pcall(require, "lazy.core.config")
  if ok and lazy_config.plugins then
    local vibing_plugin = lazy_config.plugins["vibing.nvim"]
    if vibing_plugin and vibing_plugin.dev then
      return true
    end
  end
  return false
end

---vibing.nvimプラグインの設定を初期化
---ユーザー設定とデフォルト設定をマージし、ツール権限の妥当性を検証
---permissionsで指定されたツール名が有効かチェックし、無効な場合は警告を出力
---Lazy.nvimのdev=trueが設定されている場合、node.dev_modeを自動的にtrueに設定
---@param opts? Vibing.Config ユーザー設定オブジェクト（nilの場合はデフォルト設定のみ使用）
function M.setup(opts)
  -- Capture user config before merge to detect if dev_mode was explicitly set
  local user_opts = opts or {}
  local user_dev_mode = user_opts.node and user_opts.node.dev_mode

  M.options = vim.tbl_deep_extend("force", {}, M.defaults, user_opts)

  -- Auto-detect dev_mode from Lazy.nvim if not explicitly set by user
  if user_dev_mode == nil then
    local lazy_dev = is_lazy_dev_mode()
    if lazy_dev then
      M.options.node.dev_mode = true
      notify.info("[vibing.nvim] Detected Lazy.nvim dev mode - enabling TypeScript direct execution")
    end
  end

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
    for _, tool in ipairs(M.options.permissions.ask or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.ask", tool))
      end
    end
  end

  local function validate_enum(value, valid_values, field_name, default)
    if value and not valid_values[value] then
      local valid_list = table.concat(vim.tbl_keys(valid_values), ", ")
      notify.warn(string.format(
        "Invalid %s value '%s'. Valid values: %s. Falling back to '%s'.",
        field_name, value, valid_list, default
      ))
      return default
    end
    return value
  end

  if M.options.ui then
    M.options.ui.wrap = validate_enum(
      M.options.ui.wrap,
      { nvim = true, on = true, off = true },
      "ui.wrap",
      "on"
    )
    M.options.ui.tool_result_display = validate_enum(
      M.options.ui.tool_result_display,
      { none = true, compact = true, full = true },
      "ui.tool_result_display",
      "compact"
    )
  end

  if M.options.diff then
    M.options.diff.tool = validate_enum(
      M.options.diff.tool,
      { git = true, mote = true, auto = true },
      "diff.tool",
      "auto"
    )
  end

  if M.options.ui and M.options.ui.gradient then
    local gradient = M.options.ui.gradient

    if gradient.colors then
      if type(gradient.colors) ~= "table" or #gradient.colors ~= 2 then
        notify.warn("Invalid ui.gradient.colors: must be an array of exactly 2 hex color strings.")
        M.options.ui.gradient.colors = { "#cc3300", "#fffe00" }
      else
        for i, color in ipairs(gradient.colors) do
          if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
            notify.warn(string.format(
              "Invalid color format at ui.gradient.colors[%d]: '%s'. Expected hex format like '#ff0000'.",
              i, tostring(color)
            ))
          end
        end
      end
    end

    if gradient.interval and (type(gradient.interval) ~= "number" or gradient.interval <= 0) then
      notify.warn("Invalid ui.gradient.interval: must be a positive number.")
      M.options.ui.gradient.interval = 100
    end
  end

  if M.options.ui and M.options.ui.tool_markers then
    local markers = M.options.ui.tool_markers
    for key, marker in pairs(markers) do
      if type(marker) ~= "string" then
        notify.warn(string.format("Invalid ui.tool_markers.%s: must be a string, got %s", key, type(marker)))
        M.options.ui.tool_markers[key] = nil
      elseif marker == "" then
        notify.warn(string.format("ui.tool_markers.%s is empty string - will use default", key))
        M.options.ui.tool_markers[key] = nil
      end
    end
  end

  if M.options.language then
    local function validate_lang_code(code, field_name)
      if code and code ~= "" and code ~= "en" and not language_utils.language_names[code] then
        local supported = table.concat(vim.tbl_keys(language_utils.language_names), ", ")
        notify.warn(string.format("Unknown language code '%s' in %s. Supported: %s", code, field_name, supported))
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

  if M.options.node and M.options.node.executable then
    local executable = M.options.node.executable
    if type(executable) ~= "string" or (executable ~= "auto" and executable == "") then
      notify.warn(string.format(
        "Invalid node.executable value '%s'. Must be 'auto' or a valid file path. Resetting to 'auto'.",
        tostring(executable)
      ))
      M.options.node.executable = "auto"
    elseif executable ~= "auto" and vim.fn.executable(executable) == 0 then
      notify.warn(string.format(
        "Node.js executable not found at '%s'. Resetting to 'auto'.",
        executable
      ))
      M.options.node.executable = "auto"
    end
  end
end

---現在の設定を取得
---setup()で初期化された設定オブジェクトを返す
---setup()が未実行の場合は空のテーブルを返す
---@return Vibing.Config 現在の設定オブジェクト
function M.get()
  return M.options
end

return M
