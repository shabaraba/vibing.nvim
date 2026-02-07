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

  -- チャットファイル自動検知（.md と .vibing の両方をサポート）
  -- フロントマターに vibing.nvim: true が含まれている場合にアタッチ
  local chat_detect = require("vibing.infrastructure.storage.chat_detect")
  chat_detect.setup()

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
    end
  end

  -- アダプターの初期化（agent_sdk固定）
  local AgentSDK = require("vibing.infrastructure.adapter.agent_sdk")
  M.adapter = AgentSDK:new(M.config)

  -- 終了時にクリーンアップ
  local augroup = vim.api.nvim_create_augroup("VibingCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      -- Agent SDKプロセスを全てキャンセル
      if M.adapter then
        M.adapter:cancel()
      end

      -- RPCサーバー停止
      if M.config.mcp and M.config.mcp.enabled then
        local rpc_server = require("vibing.infrastructure.rpc.server")
        rpc_server.stop()
      end
    end,
  })

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

  -- 補完システム初期化（nvim-cmpが利用可能な場合はソースを登録）
  require("vibing.application.completion").setup()
end

---Neovimユーザーコマンドを登録
---VibingChat, VibingContext, VibingInline等の全コマンドを登録
---チャット操作、コンテキスト管理、インラインアクションを含む
function M._register_commands()
  -- チャット関連コマンド
  vim.api.nvim_create_user_command("VibingChat", function(opts)
    require("vibing.presentation.chat.controller").handle_open(opts.args)
  end, {
    nargs = "?",
    desc = "Open Vibing chat with optional position (current|right|left|top|bottom|back) or file",
    complete = function(arg_lead, cmd_line, cursor_pos)
      -- First argument: position or file
      local args = vim.split(cmd_line, "%s+")
      if #args == 2 then
        -- Complete position keywords or files
        local positions = { "current", "right", "left", "top", "bottom", "back" }
        local matches = {}
        for _, pos in ipairs(positions) do
          if pos:find("^" .. vim.pesc(arg_lead)) then
            table.insert(matches, pos)
          end
        end
        -- Also add file completion
        local files = vim.fn.getcompletion(arg_lead, "file")
        for _, file in ipairs(files) do
          table.insert(matches, file)
        end
        return matches
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("VibingToggleChat", function()
    require("vibing.presentation.chat.controller").handle_toggle()
  end, { desc = "Toggle Vibing chat window" })

  vim.api.nvim_create_user_command("VibingChatFork", function(opts)
    require("vibing.presentation.chat.controller").handle_fork(opts.args)
  end, {
    nargs = "?",
    desc = "Fork current vibing chat with optional position (current|right|left|top|bottom|back)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local positions = { "current", "right", "left", "top", "bottom", "back" }
      local matches = {}
      for _, pos in ipairs(positions) do
        if pos:find("^" .. vim.pesc(arg_lead)) then
          table.insert(matches, pos)
        end
      end
      return matches
    end,
  })

  vim.api.nvim_create_user_command("VibingChatWorktree", function(opts)
    require("vibing.presentation.chat.controller").handle_open_worktree(opts.args)
  end, {
    nargs = "+",
    desc = "Open Vibing chat in git worktree with optional position ([right|left|top|bottom|back|current] <branch>)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local args = vim.split(cmd_line, "%s+")
      if #args == 2 then
        -- Complete position keywords
        local positions = { "right", "left", "top", "bottom", "back", "current" }
        local matches = {}
        for _, pos in ipairs(positions) do
          if pos:find("^" .. vim.pesc(arg_lead)) then
            table.insert(matches, pos)
          end
        end
        return matches
      elseif #args == 3 then
        -- Complete branch names
        local branches = vim.fn.systemlist("git branch --format='%(refname:short)'")
        local matches = {}
        for _, branch in ipairs(branches) do
          if branch:find("^" .. vim.pesc(arg_lead)) then
            table.insert(matches, branch)
          end
        end
        return matches
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("VibingSlashCommands", function()
    require("vibing.presentation.chat.controller").show_slash_commands()
  end, { desc = "Show slash command picker" })

  vim.api.nvim_create_user_command("VibingSetFileTitle", function()
    require("vibing.presentation.chat.controller").handle_set_file_title()
  end, { desc = "Generate AI title and rename chat file" })

  vim.api.nvim_create_user_command("VibingSummarize", function()
    require("vibing.presentation.chat.controller").handle_summarize()
  end, { desc = "Generate and insert summary from chat history" })

  vim.api.nvim_create_user_command("VibingDeleteChats", function(opts)
    require("vibing.presentation.chat.deletion_controller").handle_delete_command(opts, M.config)
  end, {
    nargs = "?",
    desc = "Delete chat files (use --unrenamed to delete all unrenamed files)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local flags = { "--unrenamed" }
      local matches = {}
      for _, flag in ipairs(flags) do
        if flag:find("^" .. vim.pesc(arg_lead)) then
          table.insert(matches, flag)
        end
      end
      return matches
    end,
  })

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

  vim.api.nvim_create_user_command("VibingCopyUnsentUserHeader", function()
    local timestamp = require("vibing.core.utils.timestamp")
    local header = timestamp.create_unsent_user_header()

    -- クリップボードプロバイダーを確認
    if vim.fn.has("clipboard") == 1 then
      vim.fn.setreg("+", header)
    else
      -- クリップボードサポートがない場合は無名レジスタに設定
      vim.fn.setreg('"', header)
    end

    notify.info("Copied to clipboard: " .. header)
  end, { desc = "Copy '## User <!-- unsent -->' to clipboard" })

  -- Daily Summary コマンド
  vim.api.nvim_create_user_command("VibingDailySummary", function(opts)
    require("vibing.presentation.daily_summary.controller").handle_daily_summary(opts.args)
  end, {
    nargs = "?",
    desc = "Generate daily summary from project chat files (default: today)",
  })

  vim.api.nvim_create_user_command("VibingDailySummaryAll", function(opts)
    require("vibing.presentation.daily_summary.controller").handle_daily_summary_all(opts.args)
  end, {
    nargs = "?",
    desc = "Generate daily summary from all chat files (default: today)",
  })
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
