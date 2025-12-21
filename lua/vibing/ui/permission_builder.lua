local notify = require("vibing.utils.notify")

---@class Vibing.PermissionBuilder
---権限設定ビルダーUI
---Telescopeまたはvim.ui.selectでツール一覧から選択し、
---permissions_allow / permissions_deny に追加
local M = {}

---組み込みツール定義
M.builtin_tools = {
  { name = "Read", description = "ファイル読み込み", type = "builtin" },
  { name = "Edit", description = "ファイル編集", type = "builtin" },
  { name = "Write", description = "ファイル書き込み", type = "builtin" },
  { name = "Bash", description = "シェルコマンド実行", type = "builtin", is_bash = true },
  { name = "Glob", description = "ファイルパターン検索", type = "builtin" },
  { name = "Grep", description = "コンテンツ検索", type = "builtin" },
  { name = "WebSearch", description = "Web検索", type = "builtin" },
  { name = "WebFetch", description = "Webコンテンツ取得", type = "builtin" },
}

---Bashコマンドプリセット
M.bash_presets = {
  { pattern = "git", description = "Gitコマンド", danger = false },
  { pattern = "npm", description = "NPMコマンド", danger = false },
  { pattern = "rm", description = "ファイル削除", danger = true },
  { pattern = "docker", description = "Dockerコマンド", danger = false },
  { pattern = "chmod", description = "パーミッション変更", danger = true },
  { pattern = "sudo", description = "特権実行", danger = true },
}

---ツールピッカーを表示
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@param callback function(tool: table) 選択後のコールバック
function M.show_picker(chat_buffer, callback)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("Invalid chat buffer")
    return
  end

  local has_telescope, _ = pcall(require, "telescope")

  if has_telescope then
    M._show_telescope(chat_buffer, callback)
  else
    M._show_native(chat_buffer, callback)
  end
end

---vim.ui.selectを使用したネイティブピッカー
---@param chat_buffer Vibing.ChatBuffer
---@param callback function(tool: table)
function M._show_native(chat_buffer, callback)
  local tool_list = {}
  for _, tool in ipairs(M.builtin_tools) do
    table.insert(tool_list, tool)
  end

  vim.ui.select(tool_list, {
    prompt = "Select tool to configure:",
    format_item = function(item)
      return string.format("%s - %s", item.name, item.description)
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

---Telescopeを使用したツールピッカー
---@param chat_buffer Vibing.ChatBuffer
---@param callback function(tool: table)
function M._show_telescope(chat_buffer, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local tool_list = {}
  for _, tool in ipairs(M.builtin_tools) do
    table.insert(tool_list, tool)
  end

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 15 },
      { remaining = true },
    },
  })

  local make_display = function(entry)
    return displayer({
      { entry.name, "TelescopeResultsIdentifier" },
      { entry.description, "TelescopeResultsString" },
    })
  end

  pickers
    .new({}, {
      prompt_title = "Permission Builder - Select Tool",
      finder = finders.new_table({
        results = tool_list,
        entry_maker = function(entry)
          return {
            value = entry,
            display = make_display,
            ordinal = entry.name .. " " .. entry.description,
            name = entry.name,
            description = entry.description,
            type = entry.type,
            is_bash = entry.is_bash or false,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            callback(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

---Bashプリセットピッカーを表示
---@param callback function(pattern: string)
function M.show_bash_preset_picker(callback)
  local preset_list = vim.tbl_map(function(preset)
    return {
      pattern = preset.pattern,
      description = preset.description,
      danger = preset.danger,
    }
  end, M.bash_presets)

  table.insert(preset_list, {
    pattern = "custom",
    description = "カスタムパターンを入力...",
    danger = false,
  })

  table.insert(preset_list, {
    pattern = "skip",
    description = "パターンなし（Bash全体）",
    danger = false,
  })

  local has_telescope, _ = pcall(require, "telescope")

  if has_telescope then
    M._show_bash_telescope(preset_list, callback)
  else
    M._show_bash_native(preset_list, callback)
  end
end

---vim.ui.selectでBashプリセット選択
---@param preset_list table[]
---@param callback function(pattern: string)
function M._show_bash_native(preset_list, callback)
  vim.ui.select(preset_list, {
    prompt = "Select Bash command pattern:",
    format_item = function(item)
      local danger_mark = item.danger and "⚠️ " or ""
      return string.format("%s%s - %s", danger_mark, item.pattern, item.description)
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice.pattern == "custom" then
      M._prompt_custom_pattern(callback)
    elseif choice.pattern == "skip" then
      callback(nil)
    else
      callback(choice.pattern)
    end
  end)
end

---TelescopeでBashプリセット選択
---@param preset_list table[]
---@param callback function(pattern: string)
function M._show_bash_telescope(preset_list, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 15 },
      { remaining = true },
    },
  })

  local make_display = function(entry)
    local danger_mark = entry.danger and "⚠️ " or ""
    return displayer({
      { danger_mark .. entry.pattern, "TelescopeResultsIdentifier" },
      { entry.description, "TelescopeResultsString" },
    })
  end

  pickers
    .new({}, {
      prompt_title = "Bash Command Pattern",
      finder = finders.new_table({
        results = preset_list,
        entry_maker = function(entry)
          return {
            value = entry,
            display = make_display,
            ordinal = entry.pattern .. " " .. entry.description,
            pattern = entry.pattern,
            description = entry.description,
            danger = entry.danger,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if not selection then
            return
          end

          if selection.pattern == "custom" then
            M._prompt_custom_pattern(callback)
          elseif selection.pattern == "skip" then
            callback(nil)
          else
            callback(selection.pattern)
          end
        end)
        return true
      end,
    })
    :find()
end

---カスタムパターンの入力プロンプト
---@param callback function(pattern: string)
function M._prompt_custom_pattern(callback)
  vim.ui.input({
    prompt = "Enter command pattern (e.g., git push): ",
  }, function(input)
    if input and input ~= "" then
      callback(input)
    end
  end)
end

---Allow/Deny選択プロンプト
---@param tool_name string ツール名
---@param callback function(permission_type: string) "allow" または "deny"
function M.prompt_permission_type(tool_name, callback)
  local choices = {
    { type = "allow", description = "Allow - このツールの使用を許可" },
    { type = "deny", description = "Deny - このツールの使用を拒否" },
  }

  vim.ui.select(choices, {
    prompt = string.format("Configure permission for '%s':", tool_name),
    format_item = function(item)
      return item.description
    end,
  }, function(choice)
    if choice then
      callback(choice.type)
    end
  end)
end

---Bashパターン選択フロー
---Bashツールの場合のみパターン選択を促す
---@param tool table ツール情報
---@param permission_type string "allow" または "deny"
---@param callback function(permission_string: string)
function M.handle_bash_pattern_selection(tool, permission_type, callback)
  if not tool.is_bash then
    local permission_string = M.build_permission_string(tool.name, nil)
    callback(permission_string)
    return
  end

  M.show_bash_preset_picker(function(pattern)
    local permission_string = M.build_permission_string(tool.name, pattern)
    callback(permission_string)
  end)
end

---権限文字列を構築
---@param tool_name string ツール名
---@param pattern string? Bashコマンドパターン
---@return string permission_string
function M.build_permission_string(tool_name, pattern)
  if tool_name == "Bash" and pattern then
    return string.format("Bash(%s:*)", pattern)
  end
  return tool_name
end

return M
