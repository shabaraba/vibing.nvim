local Config = require("vibing.config")

---@class Vibing
---@field config Vibing.Config
---@field adapter Vibing.Adapter
local M = {}

---@type Vibing.Adapter?
M.adapter = nil

---@param opts? Vibing.Config
function M.setup(opts)
  Config.setup(opts)
  M.config = Config.get()

  -- アダプターの初期化
  local adapter_name = M.config.adapter
  local ok, adapter_module = pcall(require, "vibing.adapters." .. adapter_name)
  if not ok then
    vim.notify(
      string.format("[vibing.nvim] Adapter '%s' not found", adapter_name),
      vim.log.levels.ERROR
    )
    return
  end

  M.adapter = adapter_module:new(M.config)

  -- チャットコマンド初期化
  require("vibing.chat").setup()

  -- リモートコントロールの初期化
  if M.config.remote and M.config.remote.auto_detect then
    local Remote = require("vibing.remote")
    Remote.setup(M.config.remote.socket_path)
  end

  -- コマンド登録
  M._register_commands()
end

---コマンドを登録
function M._register_commands()
  vim.api.nvim_create_user_command("VibingChat", function()
    require("vibing.actions.chat").open()
  end, { desc = "Open Vibing chat" })

  vim.api.nvim_create_user_command("VibingContext", function(opts)
    require("vibing.context").add(opts.args)
    -- チャットバッファが開いていれば表示を更新
    local chat = require("vibing.actions.chat")
    if chat.chat_buffer and chat.chat_buffer:is_open() then
      chat.chat_buffer:_update_context_line()
    end
  end, { nargs = "?", desc = "Add context to Vibing", complete = "file" })

  vim.api.nvim_create_user_command("VibingClearContext", function()
    require("vibing.context").clear()
    -- チャットバッファが開いていれば表示を更新
    local chat = require("vibing.actions.chat")
    if chat.chat_buffer and chat.chat_buffer:is_open() then
      chat.chat_buffer:_update_context_line()
    end
  end, { desc = "Clear Vibing context" })

  vim.api.nvim_create_user_command("VibingInline", function(opts)
    require("vibing.actions.inline").execute(opts.args)
  end, { nargs = "?", range = true, desc = "Run inline action" })

  -- Individual inline action commands
  vim.api.nvim_create_user_command("VibingExplain", function()
    require("vibing.actions.inline").execute("explain")
  end, { range = true, desc = "Explain selected code" })

  vim.api.nvim_create_user_command("VibingFix", function()
    require("vibing.actions.inline").execute("fix")
  end, { range = true, desc = "Fix selected code issues" })

  vim.api.nvim_create_user_command("VibingFeature", function()
    require("vibing.actions.inline").execute("feat")
  end, { range = true, desc = "Implement feature in selected code" })

  vim.api.nvim_create_user_command("VibingRefactor", function()
    require("vibing.actions.inline").execute("refactor")
  end, { range = true, desc = "Refactor selected code" })

  vim.api.nvim_create_user_command("VibingTest", function()
    require("vibing.actions.inline").execute("test")
  end, { range = true, desc = "Generate tests for selected code" })

  vim.api.nvim_create_user_command("VibingCustom", function(opts)
    require("vibing.actions.inline").custom(opts.args, false)
  end, { nargs = 1, range = true, desc = "Execute custom instruction on selected code" })

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
      vim.notify("[vibing] Remote control not available. Start nvim with --listen or set socket_path", vim.log.levels.ERROR)
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
      vim.notify("[vibing] Remote control not available", vim.log.levels.ERROR)
    end
  end, { desc = "Get remote Neovim status" })

  vim.api.nvim_create_user_command("VibingSendToChat", function()
    require("vibing.integrations.oil").send_to_chat()
  end, { desc = "Send file from oil.nvim to chat" })

  vim.api.nvim_create_user_command("VibingMigrate", function(opts)
    local Migrator = require("vibing.context.migrator")
    local args = opts.args

    if args == "" then
      -- 引数なし：現在のチャットバッファをマイグレーション
      local chat = require("vibing.actions.chat")
      if not chat.chat_buffer or not chat.chat_buffer.file_path then
        vim.notify("[vibing] No active chat buffer to migrate", vim.log.levels.WARN)
        return
      end

      local success, err = Migrator.migrate_current_buffer(chat.chat_buffer)
      if success then
        vim.notify("[vibing] Chat migrated successfully", vim.log.levels.INFO)
        -- バッファを再読み込み
        vim.cmd("edit!")
      else
        vim.notify("[vibing] Migration failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
      end
    elseif args == "--scan" then
      -- ディレクトリスキャン
      local chat_dir = vim.fn.getcwd() .. "/.vibing/chat"
      local files = Migrator.scan_chat_directory(chat_dir)

      if #files == 0 then
        vim.notify("[vibing] No old format files found", vim.log.levels.INFO)
        return
      end

      vim.notify(
        string.format("[vibing] Found %d file(s) to migrate. Migrating...", #files),
        vim.log.levels.INFO
      )

      local success_count = 0
      for _, file in ipairs(files) do
        local success, err = Migrator.migrate_file(file, true)
        if success then
          success_count = success_count + 1
        else
          vim.notify("[vibing] Failed to migrate " .. file .. ": " .. (err or ""), vim.log.levels.WARN)
        end
      end

      vim.notify(
        string.format("[vibing] Migrated %d/%d files successfully", success_count, #files),
        vim.log.levels.INFO
      )
    else
      -- ファイルパス指定
      local file_path = vim.fn.expand(args)
      local success, err = Migrator.migrate_file(file_path, true)
      if success then
        vim.notify("[vibing] File migrated: " .. file_path, vim.log.levels.INFO)
      else
        vim.notify("[vibing] Migration failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
      end
    end
  end, { nargs = "?", desc = "Migrate chat file to new format", complete = "file" })
end

---@return Vibing.Adapter?
function M.get_adapter()
  return M.adapter
end

---@return Vibing.Config
function M.get_config()
  return M.config or Config.defaults
end

return M
