local notify = require("vibing.utils.notify")
local tools_const = require("vibing.constants.tools")

---@class Vibing.PermissionPicker
---権限設定ピッカーUI
---Telescopeまたはvim.ui.selectでツール一覧から選択し、allow/denyを設定
---Bashコマンドの引数パターン指定にも対応
local M = {}

---@class Vibing.ToolItem
---@field name string ツール名
---@field description string ツールの説明
---@field type "builtin"|"mcp" ツールタイプ
---@field mcp_server string? MCPサーバー名（type="mcp"の場合のみ）

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

---組み込みツールのリストを取得
---@return Vibing.ToolItem[]
local function get_builtin_tools()
  local tools = {}
  for _, name in ipairs(tools_const.VALID_TOOLS) do
    table.insert(tools, {
      name = name,
      description = TOOL_DESCRIPTIONS[name] or "No description",
      type = "builtin",
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

---権限ピッカーを表示
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M.show(chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("Invalid chat buffer", "Permission")
    return
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
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M._show_native(chat_buffer)
  local all_tools = get_all_tools()

  -- vim.ui.selectで選択
  vim.ui.select(all_tools, {
    prompt = "Select tool to configure permissions:",
    format_item = function(item)
      local type_tag = item.type == "mcp" and "[MCP:" .. (item.mcp_server or "unknown") .. "] " or "[builtin] "
      return string.format("%s%s - %s", type_tag, item.name, item.description)
    end,
  }, function(choice)
    if choice then
      M._handle_tool_selection(choice, chat_buffer)
    end
  end)
end

---Telescopeを使用したリッチピッカー
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M._show_telescope(chat_buffer)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local all_tools = get_all_tools()

  -- エントリーメーカー: 表示フォーマットを定義
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 20 },  -- source
      { width = 20 },  -- tool name
      { remaining = true },  -- description
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

  -- Telescopeピッカーを作成
  pickers.new({}, {
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
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          M._handle_tool_selection(selection.value, chat_buffer)
        end
      end)
      return true
    end,
  }):find()
end

---ツール選択後の処理: allow/denyを選択
---@param tool Vibing.ToolItem 選択されたツール
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M._handle_tool_selection(tool, chat_buffer)
  local permission_types = {
    { value = "allow", label = "Allow - ツールの使用を許可" },
    { value = "deny", label = "Deny  - ツールの使用を拒否" },
  }

  vim.ui.select(permission_types, {
    prompt = string.format("Permission type for '%s':", tool.name),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M._handle_permission_type(tool, choice.value, chat_buffer)
    end
  end)
end

---権限タイプ選択後の処理: Bashの場合は引数パターンを入力
---@param tool Vibing.ToolItem 選択されたツール
---@param permission_type "allow"|"deny" 権限タイプ
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M._handle_permission_type(tool, permission_type, chat_buffer)
  if tool.name == "Bash" then
    -- Bashの場合は引数パターンを入力
    M._prompt_bash_pattern(tool, permission_type, chat_buffer)
  else
    -- 他のツールはそのまま追加
    M._add_permission(chat_buffer, permission_type, tool.name)
  end
end

---Bashコマンドの引数パターンを入力
---@param tool Vibing.ToolItem 選択されたツール
---@param permission_type "allow"|"deny" 権限タイプ
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
function M._prompt_bash_pattern(tool, permission_type, chat_buffer)
  -- プリセットパターンを提供
  local presets = {
    { pattern = "*", label = "All commands (Bash)" },
    { pattern = "rm:*", label = "All 'rm' commands" },
    { pattern = "git:*", label = "All 'git' commands" },
    { pattern = "npm:*", label = "All 'npm' commands" },
    { pattern = "docker:*", label = "All 'docker' commands" },
    { pattern = "", label = "Custom pattern (type manually)" },
  }

  vim.ui.select(presets, {
    prompt = "Select Bash command pattern:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice.pattern == "" then
      -- カスタムパターンを入力
      vim.ui.input({
        prompt = "Enter Bash command pattern (e.g., 'rm:*' or 'git push:*'): ",
      }, function(input)
        if input and vim.trim(input) ~= "" then
          local tool_name = string.format("Bash(%s)", input)
          M._add_permission(chat_buffer, permission_type, tool_name)
        end
      end)
    else
      -- プリセットパターンを使用
      local tool_name = choice.pattern == "*" and "Bash" or string.format("Bash(%s)", choice.pattern)
      M._add_permission(chat_buffer, permission_type, tool_name)
    end
  end)
end

---権限をフロントマターに追加
---@param chat_buffer Vibing.ChatBuffer 権限を設定するチャットバッファ
---@param permission_type "allow"|"deny" 権限タイプ
---@param tool_name string ツール名（Bash(rm:*)などの形式も可）
function M._add_permission(chat_buffer, permission_type, tool_name)
  local buf = chat_buffer.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid buffer", "Permission")
    return
  end

  -- フロントマターを解析
  local frontmatter = chat_buffer:parse_frontmatter()

  -- permissions_allow または permissions_deny に追加
  local field_name = permission_type == "allow" and "permissions_allow" or "permissions_deny"
  local current_list = frontmatter[field_name] or {}

  -- 既に存在するかチェック
  local already_exists = false
  for _, existing_tool in ipairs(current_list) do
    if existing_tool == tool_name then
      already_exists = true
      break
    end
  end

  if already_exists then
    notify.warn(string.format("'%s' is already in %s", tool_name, field_name), "Permission")
    return
  end

  -- 追加
  table.insert(current_list, tool_name)
  frontmatter[field_name] = current_list

  -- フロントマターを更新
  local success = chat_buffer:update_frontmatter(frontmatter)
  if success then
    notify.info(string.format("Added '%s' to %s", tool_name, field_name), "Permission")
  else
    notify.error(string.format("Failed to update %s", field_name), "Permission")
  end
end

return M
