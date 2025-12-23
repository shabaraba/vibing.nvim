local Config = require("vibing.config")
local notify = require("vibing.utils.notify")

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
    local rpc_server = require("vibing.rpc_server")
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
  local AgentSDK = require("vibing.adapters.agent_sdk")
  M.adapter = AgentSDK:new(M.config)

  -- チャットコマンド初期化
  require("vibing.chat").setup()

  -- カスタムコマンドのスキャンと登録
  local custom_commands = require("vibing.chat.custom_commands")
  local commands = require("vibing.chat.commands")
  for _, custom_cmd in ipairs(custom_commands.get_all()) do
    commands.register_custom(custom_cmd)
  end

  -- リモートコントロールの初期化
  if M.config.remote and M.config.remote.auto_detect then
    local Remote = require("vibing.remote")
    Remote.setup(M.config.remote.socket_path)
  end

  -- コマンド登録
  M._register_commands()
end

---Neovimユーザーコマンドを登録
---VibingChat, VibingContext, VibingInline, VibingExplain, VibingFix等の全コマンドを登録
---チャット操作、コンテキスト管理、インラインアクション、リモート制御、マイグレーションを含む
function M._register_commands()
  vim.api.nvim_create_user_command("VibingChat", function(opts)
    if opts.args ~= "" then
      require("vibing.actions.chat").open_file(opts.args)
    else
      require("vibing.actions.chat").open()
    end
  end, { nargs = "?", desc = "Open Vibing chat or chat file", complete = "file" })

  vim.api.nvim_create_user_command("VibingToggleChat", function()
    require("vibing.actions.chat").toggle()
  end, { desc = "Toggle Vibing chat window" })

  vim.api.nvim_create_user_command("VibingSlashCommands", function()
    local chat = require("vibing.actions.chat")
    if not chat.chat_buffer or not chat.chat_buffer:is_open() then
      notify.warn("Please open a chat window first")
      return
    end
    require("vibing.ui.command_picker").show(chat.chat_buffer)
  end, { desc = "Show slash command picker" })

  vim.api.nvim_create_user_command("VibingContext", function(opts)
    -- 引数なしの場合、oil.nvimバッファからファイルを追加
    if opts.args == "" then
      local ok, oil = pcall(require, "vibing.integrations.oil")
      if ok and oil.is_oil_buffer() then
        local send_ok, err = pcall(oil.send_to_chat)
        if send_ok then
          return
        end
        -- エラーがあっても続行（通常のコンテキスト追加にフォールスルー）
      end
    end

    require("vibing.context").add(opts.args)
    -- チャットバッファが開いていれば表示を更新
    local chat = require("vibing.actions.chat")
    if chat.chat_buffer and chat.chat_buffer:is_open() then
      chat.chat_buffer:_update_context_line()
    end
  end, { nargs = "?", desc = "Add file to context (or from oil.nvim)", complete = "file" })

  vim.api.nvim_create_user_command("VibingClearContext", function()
    require("vibing.context").clear()
    -- チャットバッファが開いていれば表示を更新
    local chat = require("vibing.actions.chat")
    if chat.chat_buffer and chat.chat_buffer:is_open() then
      chat.chat_buffer:_update_context_line()
    end
  end, { desc = "Clear Vibing context" })

  vim.api.nvim_create_user_command("VibingInline", function(opts)
    if opts.args == "" then
      -- 引数なしの場合はリッチなピッカーUIを表示
      local InlinePicker = require("vibing.ui.inline_picker")
      InlinePicker.show(function(action, instruction)
        local action_arg = action
        if instruction and instruction ~= "" then
          action_arg = action_arg .. " " .. instruction
        end
        require("vibing.actions.inline").execute(action_arg)
      end)
    else
      require("vibing.actions.inline").execute(opts.args)
    end
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

  -- VibingInlineActionはVibingInlineへのエイリアス（後方互換性）
  vim.api.nvim_create_user_command("VibingInlineAction", function()
    local InlinePicker = require("vibing.ui.inline_picker")
    InlinePicker.show(function(action, instruction)
      local action_arg = action
      if instruction and instruction ~= "" then
        action_arg = action_arg .. " " .. instruction
      end
      require("vibing.actions.inline").execute(action_arg)
    end)
  end, { range = true, desc = "Interactive inline action picker (alias of VibingInline)" })

  vim.api.nvim_create_user_command("VibingCancel", function()
    if M.adapter then
      M.adapter:cancel()
    end
  end, { desc = "Cancel current Vibing request" })

  vim.api.nvim_create_user_command("VibingOpenChat", function(opts)
    require("vibing.actions.chat").open_file(opts.args)
  end, { nargs = 1, desc = "Open saved chat file", complete = "file" })

  vim.api.nvim_create_user_command("VibingRemote", function(opts)
    local remote = require("vibing.remote")
    if not remote.is_available() then
      notify.error("Remote control not available. Start nvim with --listen or set socket_path")
      return
    end
    remote.execute(opts.args)
  end, { nargs = 1, desc = "Execute command in remote Neovim instance" })

  vim.api.nvim_create_user_command("VibingRemoteStatus", function()
    local remote = require("vibing.remote")
    local status = remote.get_status()
    if status then
      print(string.format("[vibing] Remote Status - Mode: %s, Buffer: %s, Line: %d, Col: %d",
        status.mode, status.bufname, status.line, status.col))
    else
      notify.error("Remote control not available")
    end
  end, { desc = "Get remote Neovim status" })

  vim.api.nvim_create_user_command("VibingSendToChat", function()
    require("vibing.integrations.oil").send_to_chat()
  end, { desc = "Send file from oil.nvim to chat" })

  vim.api.nvim_create_user_command("VibingReloadCommands", function()
    local custom_commands = require("vibing.chat.custom_commands")
    local commands = require("vibing.chat.commands")

    custom_commands.clear_cache()
    commands.custom_commands = {}

    for _, custom_cmd in ipairs(custom_commands.get_all()) do
      commands.register_custom(custom_cmd)
    end

    notify.info("Custom commands reloaded")
  end, { desc = "Reload custom slash commands" })

  vim.api.nvim_create_user_command("VibingMigrate", function(opts)
    local Migrator = require("vibing.context.migrator")
    local args = opts.args

    if args == "" then
      -- 引数なし：現在のチャットバッファをマイグレーション
      local chat = require("vibing.actions.chat")
      if not chat.chat_buffer or not chat.chat_buffer.file_path then
        notify.warn("No active chat buffer to migrate")
        return
      end

      local success, err = Migrator.migrate_current_buffer(chat.chat_buffer)
      if success then
        notify.info("Chat migrated successfully")
        -- バッファを再読み込み
        vim.cmd("edit!")
      else
        notify.error("Migration failed: " .. (err or "unknown error"))
      end
    elseif args == "--scan" then
      -- ディレクトリスキャン
      local chat_dir = vim.fn.getcwd() .. "/.vibing/chat"
      local files = Migrator.scan_chat_directory(chat_dir)

      if #files == 0 then
        notify.info("No old format files found")
        return
      end

      notify.info(string.format("Found %d file(s) to migrate. Migrating...", #files))

      local success_count = 0
      for _, file in ipairs(files) do
        local success, err = Migrator.migrate_file(file, true)
        if success then
          success_count = success_count + 1
        else
          notify.warn("Failed to migrate " .. file .. ": " .. (err or ""))
        end
      end

      notify.info(string.format("Migrated %d/%d files successfully", success_count, #files))
    else
      -- ファイルパス指定
      local file_path = vim.fn.expand(args)
      local success, err = Migrator.migrate_file(file_path, true)
      if success then
        notify.info("File migrated: " .. file_path)
      else
        notify.error("Migration failed: " .. (err or "unknown error"))
      end
    end
  end, { nargs = "?", desc = "Migrate chat file to new format", complete = "file" })

  -- MCP関連コマンド
  vim.api.nvim_create_user_command("VibingBuildMcp", function()
    local mcp_setup = require("vibing.mcp.setup")
    mcp_setup.build_mcp_server()
  end, { desc = "Build vibing.nvim MCP server" })

  vim.api.nvim_create_user_command("VibingSetupMcp", function()
    local mcp_setup = require("vibing.mcp.setup")
    mcp_setup.setup_wizard(M.config)
  end, { desc = "Interactive MCP setup wizard" })

  vim.api.nvim_create_user_command("VibingConfigureClaude", function()
    local mcp_setup = require("vibing.mcp.setup")
    mcp_setup.setup_claude_json({ force = true, port = M.config.mcp.rpc_port })
  end, { desc = "Configure ~/.claude.json for vibing.nvim" })
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
