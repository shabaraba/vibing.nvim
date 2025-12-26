local notify = require("vibing.utils.notify")
local tools_const = require("vibing.constants.tools")

---@class Vibing.PermissionBuilder
---権限設定ビルダーUI
---Telescopeまたはvim.ui.selectでツール一覧から選択し、
---permissions_allow / permissions_deny に追加
local M = {}

---@class Vibing.ToolItem
---@field name string ツール名
---@field description string ツールの説明
---@field type "builtin"|"mcp" ツールタイプ
---@field mcp_server string? MCPサーバー名（type="mcp"の場合のみ）
---@field is_bash boolean? Bashツールかどうか

---組み込みツールの説明
---@type table<string, string>
local TOOL_DESCRIPTIONS = {
  Read = "Read files from the filesystem",
  Edit = "Edit existing files with find/replace",
  Write = "Create new files or overwrite existing ones",
  Bash = "Execute shell commands",
  Glob = "Find files by pattern matching",
  Grep = "Search for patterns in files",
  WebSearch = "Search the web for information",
  WebFetch = "Fetch content from URLs",
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

---組み込みツールのリストを取得
---@return Vibing.ToolItem[]
local function get_builtin_tools()
  local tools = {}
  for _, name in ipairs(tools_const.VALID_TOOLS) do
    table.insert(tools, {
      name = name,
      description = TOOL_DESCRIPTIONS[name] or "No description",
      type = "builtin",
      is_bash = (name == "Bash"),
    })
  end
  return tools
end

---MCPツールのリストを取得
---現在は未実装（将来の拡張用）
---@return Vibing.ToolItem[]
local function get_mcp_tools()
  -- TODO: アダプターからMCPツールを取得する実装を追加
  return {}
end

---全ツールのリストを取得（組み込み + MCP）
---@return Vibing.ToolItem[]
local function get_all_tools()
  local tools = {}
  vim.list_extend(tools, get_builtin_tools())
  vim.list_extend(tools, get_mcp_tools())
  return tools
end

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
  local all_tools = get_all_tools()

  vim.ui.select(all_tools, {
    prompt = "Select tool to configure:",
    format_item = function(item)
      local type_tag = item.type == "mcp" and "[MCP:" .. (item.mcp_server or "unknown") .. "] " or "[builtin] "
      return string.format("%s%s - %s", type_tag, item.name, item.description)
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

  local all_tools = get_all_tools()

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 20 }, -- source
      { width = 15 }, -- tool name
      { remaining = true }, -- description
    },
  })

  local make_display = function(entry)
    local source_display = ""
    if entry.type == "builtin" then
      source_display = "[vibing:builtin]"
    elseif entry.type == "mcp" then
      source_display = "[MCP:" .. (entry.mcp_server or "unknown") .. "]"
    end

    return displayer({
      { source_display, "TelescopeResultsComment" },
      { entry.name, "TelescopeResultsIdentifier" },
      { entry.description, "TelescopeResultsString" },
    })
  end

  pickers
    .new({}, {
      prompt_title = "Permission Builder - Select Tool",
      finder = finders.new_table({
        results = all_tools,
        entry_maker = function(entry)
          return {
            value = entry,
            display = make_display,
            ordinal = entry.name .. " " .. entry.description,
            name = entry.name,
            description = entry.description,
            type = entry.type,
            mcp_server = entry.mcp_server,
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
    { type = "ask", description = "Ask - このツールの使用前に確認を要求" },
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
