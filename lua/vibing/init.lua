local Config = require("vibing.config")
local notify = require("vibing.core.utils.notify")

---@class Vibing
---vibing.nvimプラグインのメインモジュール
---設定管理、アダプター初期化、コマンド登録を担当するエントリーポイント
---@field config Vibing.Config プラグイン設定オブジェクト（setup()で初期化）
---@field adapter Vibing.Adapter AIバックエンドアダプター（agent_sdk, claude, claude_acp等）
local M = {}

---現在使用中のアダプターインスタンス
---setup()でconfig.adapterに基づいて初期化される
---@type Vibing.Adapter?
M.adapter = nil

---vibing.nvimプラグインを初期化
---設定のマージ、アダプター初期化、チャットシステム初期化、リモート制御初期化、ユーザーコマンド登録を実行
---アダプター読み込みに失敗した場合はエラー通知して初期化を中断
---@param opts? Vibing.Config ユーザー設定オブジェクト（nilの場合はデフォルト設定のみ使用）
function M.setup(opts)
  Config.setup(opts)
  M.config = Config.get()

  -- Register .vibing filetype
  vim.filetype.add({
    extension = {
      vibing = "vibing",
    },
  })

  -- MCP統合の初期化
  if M.config.mcp and M.config.mcp.enabled then
    -- 自動セットアップ（初回のみ）
    local mcp_setup = require("vibing.mcp.setup")
    mcp_setup.auto_setup(M.config)

    -- RPCサーバー起動
    local rpc_server = require("vibing.infrastructure.rpc.server")
    local port = rpc_server.start(M.config.mcp.rpc_port)
    if port > 0 then
      notify.info(string.format("MCP RPC server started on port %d", port))

      -- 終了時にクリーンアップ
      vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
          rpc_server.stop()
        end,
      })
    end
  end

  -- アダプターの初期化（agent_sdk固定）
  local AgentSDK = require("vibing.infrastructure.adapter.agent_sdk")
  M.adapter = AgentSDK:new(M.config)

  -- チャットコマンド初期化
  require("vibing.application.chat").setup()

  -- カスタムコマンドのスキャンと登録
  local custom_commands = require("vibing.application.chat.custom_commands")
  local commands = require("vibing.application.chat.commands")
  for _, custom_cmd in ipairs(custom_commands.get_all()) do
    commands.register_custom(custom_cmd)
  end

  -- コマンド登録
  M._register_commands()
end

---Neovimユーザーコマンドを登録
---VibingChat, VibingContext, VibingInline等の全コマンドを登録
---チャット操作、コンテキスト管理、インラインアクションを含む
function M._register_commands()
  -- チャット関連コマンド
  vim.api.nvim_create_user_command("VibingChat", function(opts)
    require("vibing.presentation.chat.controller").handle_open(opts.args)
  end, { nargs = "?", desc = "Open Vibing chat or chat file", complete = "file" })

  vim.api.nvim_create_user_command("VibingToggleChat", function()
    require("vibing.presentation.chat.controller").handle_toggle()
  end, { desc = "Toggle Vibing chat window" })

  vim.api.nvim_create_user_command("VibingSlashCommands", function()
    require("vibing.presentation.chat.controller").show_slash_commands()
  end, { desc = "Show slash command picker" })

  vim.api.nvim_create_user_command("VibingSetFileTitle", function()
    require("vibing.presentation.chat.controller").handle_set_file_title()
  end, { desc = "Generate AI title and rename chat file" })

  -- コンテキスト関連コマンド
  vim.api.nvim_create_user_command("VibingContext", function(opts)
    require("vibing.presentation.context.controller").handle_add(opts)
  end, {
    nargs = "?",
    desc = "Add file or selection to context (or from oil.nvim)",
    complete = "file",
    range = true,
  })

  vim.api.nvim_create_user_command("VibingClearContext", function()
    require("vibing.presentation.context.controller").handle_clear()
  end, { desc = "Clear Vibing context" })

  -- インライン関連コマンド
  vim.api.nvim_create_user_command("VibingInline", function(opts)
    require("vibing.presentation.inline.controller").handle_execute(opts.args)
  end, {
    nargs = "?",
    range = true,
    desc = "Run inline action or custom instruction",
    complete = function(ArgLead, CmdLine, CursorPos)
      local actions = { "fix", "feat", "explain", "refactor", "test" }
      local matches = {}
      for _, action in ipairs(actions) do
        if action:find("^" .. vim.pesc(ArgLead)) then
          table.insert(matches, action)
        end
      end
      return matches
    end,
  })

  -- その他のコマンド
  vim.api.nvim_create_user_command("VibingCancel", function()
    if M.adapter then
      M.adapter:cancel()
    end
  end, { desc = "Cancel current Vibing request" })

  vim.api.nvim_create_user_command("VibingReloadCommands", function()
    local custom_commands = require("vibing.application.chat.custom_commands")
    local commands = require("vibing.application.chat.commands")

    custom_commands.clear_cache()
    commands.custom_commands = {}

    for _, custom_cmd in ipairs(custom_commands.get_all()) do
      commands.register_custom(custom_cmd)
    end

    notify.info("Custom commands reloaded")
  end, { desc = "Reload custom slash commands" })
end

---現在のアダプターインスタンスを取得
---setup()で初期化されたアダプター（agent_sdk, claude, claude_acp等）を返す
---setup()未実行の場合はnilを返す
---@return Vibing.Adapter? アダプターインスタンス（初期化済みの場合）またはnil
function M.get_adapter()
  return M.adapter
end

---現在の設定を取得
---setup()で初期化された設定を返す
---setup()未実行の場合はデフォルト設定を返す
---@return Vibing.Config 現在の設定オブジェクトまたはデフォルト設定
function M.get_config()
  return M.config or Config.defaults
end

return M
