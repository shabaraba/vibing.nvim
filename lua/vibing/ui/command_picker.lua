local notify = require("vibing.utils.notify")
local commands = require("vibing.chat.commands")

---@class Vibing.CommandPicker
---スラッシュコマンドピッカーUI
---Telescopeまたはvim.ui.selectでコマンド一覧から選択
---引数補完が必要なコマンド（/mode, /model）にも対応
local M = {}

---コマンドピッカーを表示
---Telescopeが利用可能ならリッチなピッカー、なければvim.ui.selectを使用
---@param chat_buffer? Vibing.ChatBuffer コマンドを挿入するチャットバッファ（nilの場合はブラウズ専用）
function M.show(chat_buffer)
  -- チャットバッファが提供されていない場合は、現在開いているチャットを探す
  if not chat_buffer then
    local chat = require("vibing.actions.chat")

    -- 1. グローバルなchat_bufferをチェック
    if chat.chat_buffer and chat.chat_buffer:is_open() then
      chat_buffer = chat.chat_buffer
    else
      -- 2. 現在のバッファが.vibingファイルかチェック
      local current_buf = vim.api.nvim_get_current_buf()
      local filetype = vim.bo[current_buf].filetype
      if filetype == "vibing" then
        -- 現在のバッファがvibingファイルなら、それをチャットバッファとして取得
        chat_buffer = chat.get_current_chat_buffer()
      end
    end
    -- chat_bufferがまだnilの場合はブラウズ専用モード
  end

  -- Telescopeが利用可能かチェック
  local has_telescope, _ = pcall(require, "telescope")

  if has_telescope then
    M._show_telescope(chat_buffer)
  else
    M._show_native(chat_buffer)
  end
end

---vim.ui.selectを使用したネイティブピッカー
---@param chat_buffer? Vibing.ChatBuffer コマンドを挿入するチャットバッファ（nilの場合はブラウズ専用）
function M._show_native(chat_buffer)
  local all_commands = commands.list_all()

  -- コマンドリストを構築（ソート済み）
  local command_list = {}
  for name, cmd in pairs(all_commands) do
    table.insert(command_list, {
      name = name,
      description = cmd.description,
      source = cmd.source or "builtin",
      requires_args = cmd.requires_args or false,
      plugin_name = cmd.plugin_name,
    })
  end

  table.sort(command_list, function(a, b)
    return a.name < b.name
  end)

  -- vim.ui.selectで選択
  vim.ui.select(command_list, {
    prompt = "Select slash command:",
    format_item = function(item)
      local source_tag = ""
      if item.source == "project" then
        source_tag = "[project] "
      elseif item.source == "user" then
        source_tag = "[user] "
      elseif item.source == "plugin" then
        if item.plugin_name then
          source_tag = string.format("[plugin:%s] ", item.plugin_name)
        else
          source_tag = "[plugin] "
        end
      end
      local args_indicator = item.requires_args and " <args>" or ""
      return string.format("%s/%s%s - %s", source_tag, item.name, args_indicator, item.description)
    end,
  }, function(choice)
    if choice then
      M._handle_selection(choice.name, chat_buffer)
    end
  end)
end

---Telescopeを使用したリッチピッカー
---@param chat_buffer? Vibing.ChatBuffer コマンドを挿入するチャットバッファ（nilの場合はブラウズ専用）
function M._show_telescope(chat_buffer)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local all_commands = commands.list_all()

  -- コマンドリストを構築
  local command_list = {}
  for name, cmd in pairs(all_commands) do
    table.insert(command_list, {
      name = name,
      description = cmd.description,
      source = cmd.source or "builtin",
      requires_args = cmd.requires_args or false,
      plugin_name = cmd.plugin_name,
    })
  end

  table.sort(command_list, function(a, b)
    return a.name < b.name
  end)

  -- エントリーメーカー: 表示フォーマットを定義
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 20 },  -- source (increased for plugin names)
      { width = 25 },  -- command name (with args indicator)
      { remaining = true },  -- description
    },
  })

  local make_display = function(entry)
    local source_display = ""
    if entry.source == "builtin" then
      source_display = "[vibing]"
    elseif entry.source == "project" then
      source_display = "[custom:project]"
    elseif entry.source == "user" then
      source_display = "[custom:user]"
    elseif entry.source == "plugin" then
      if entry.plugin_name then
        source_display = string.format("[plugin:%s]", entry.plugin_name)
      else
        source_display = "[plugin]"
      end
    end

    local command_display = "/" .. entry.name
    if entry.requires_args then
      command_display = command_display .. " <args>"
    end

    return displayer({
      { source_display, "TelescopeResultsComment" },
      { command_display, "TelescopeResultsIdentifier" },
      { entry.description, "TelescopeResultsString" },
    })
  end

  -- Telescopeピッカーを作成
  pickers.new({}, {
    prompt_title = "Slash Commands",
    finder = finders.new_table({
      results = command_list,
      entry_maker = function(entry)
        return {
          value = entry,
          display = make_display,
          ordinal = entry.name .. " " .. entry.description,
          name = entry.name,
          description = entry.description,
          source = entry.source,
          requires_args = entry.requires_args,
          plugin_name = entry.plugin_name,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          M._handle_selection(selection.name, chat_buffer)
        end
      end)
      return true
    end,
  }):find()
end

---選択されたコマンドを処理
---引数補完が必要な場合は追加の選択UIを表示
---@param command_name string 選択されたコマンド名
---@param chat_buffer? Vibing.ChatBuffer コマンドを挿入するチャットバッファ（nilの場合はブラウズ専用）
function M._handle_selection(command_name, chat_buffer)
  -- チャットバッファがない場合はブラウズ専用モード（情報表示のみ）
  if not chat_buffer then
    local all_commands = commands.list_all()
    local cmd = all_commands[command_name]
    if cmd then
      local info_lines = {
        string.format("Command: /%s", command_name),
        string.format("Description: %s", cmd.description or "No description"),
        string.format("Source: %s", cmd.source or "unknown"),
      }
      if cmd.plugin_name then
        table.insert(info_lines, string.format("Plugin: %s", cmd.plugin_name))
      end
      if cmd.requires_args then
        table.insert(info_lines, "Arguments: Required")
      end
      notify.info(table.concat(info_lines, "\n"))
    end
    return
  end

  -- 引数補完が必要かチェック
  local arg_completions = commands.get_argument_completions(command_name)

  if arg_completions and #arg_completions > 0 then
    -- 引数選択UIを表示
    vim.ui.select(arg_completions, {
      prompt = string.format("Select argument for /%s:", command_name),
    }, function(choice)
      if choice then
        M._insert_command(chat_buffer, command_name, choice)
      end
    end)
  else
    -- 引数不要の場合はそのまま挿入
    M._insert_command(chat_buffer, command_name)
  end
end

---コマンドをチャットバッファに挿入
---@param chat_buffer? Vibing.ChatBuffer 挿入先のチャットバッファ
---@param command_name string コマンド名
---@param argument string? コマンド引数（オプショナル）
function M._insert_command(chat_buffer, command_name, argument)
  if not chat_buffer then
    notify.warn("No chat buffer available. Open a chat window first to use commands.")
    return
  end
  local buf = chat_buffer.buf
  local win = chat_buffer.win

  if not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid buffer")
    return
  end

  if not win or not vim.api.nvim_win_is_valid(win) then
    notify.error("Invalid window")
    return
  end

  -- チャットウィンドウにフォーカス
  vim.api.nvim_set_current_win(win)

  -- コマンド文字列を構築
  local command_text = "/" .. command_name
  if argument then
    command_text = command_text .. " " .. argument
  end

  -- カーソル位置に挿入
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1  -- 0-based
  local col = cursor[2]

  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local new_line = line:sub(1, col) .. command_text .. line:sub(col + 1)

  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { new_line })

  -- カーソルを挿入後の位置に移動
  vim.api.nvim_win_set_cursor(win, { row + 1, col + #command_text })

  -- 確実にノーマルモードに戻す
  vim.cmd("stopinsert")

  notify.info(string.format("Inserted: %s", command_text))
end

return M
