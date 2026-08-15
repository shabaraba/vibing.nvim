local notify = require("vibing.core.utils.notify")
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
  Skill = "Invoke a Claude Code skill",
  StructuredOutput = "Return a schema-validated response",
}

---ツール名 → 引数の種類。`matchers.parse_tool_pattern` が解釈できる形だけを載せる。
---ここに無いツール（Skill / StructuredOutput）にはピッカーから引数を付けさせない。
---`matchers` は未知の形を `unknown_pattern` として黙って不一致にするので、付けられるようにすると
---「ルールを作ったのに永久にマッチしない」という静かな不具合になる。
---@type table<string, "bash"|"path"|"domain"|"literal">
M.ARG_KIND = {
  Bash = "bash",
  Read = "path",
  Write = "path",
  Edit = "path",
  WebFetch = "domain",
  WebSearch = "domain",
  Glob = "literal",
  Grep = "literal",
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

---パスパターンのプリセット（Read / Write / Edit）
---`danger` が付くものは deny 向けの例。allow で選ぶと機密ファイルを開放してしまうため警告を出す。
M.path_presets = {
  { pattern = "src/**", description = "ソースツリー全体", danger = false },
  { pattern = "tests/**", description = "テストツリー全体", danger = false },
  { pattern = "handbook/**", description = "ドキュメント", danger = false },
  { pattern = ".env", description = "環境変数ファイル（deny向け）", danger = true },
  { pattern = "*.secret", description = "シークレットファイル（deny向け）", danger = true },
  { pattern = "*.key", description = "鍵ファイル（deny向け）", danger = true },
}

---ドメインのプリセット（WebFetch / WebSearch）
M.domain_presets = {
  { pattern = "github.com", description = "GitHub", danger = false },
  { pattern = "*.npmjs.com", description = "npm レジストリ", danger = false },
  { pattern = "docs.rs", description = "Rust ドキュメント", danger = false },
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

---引数の種類ごとのプリセットとプロンプト文言
---@param kind "bash"|"path"|"domain"|"literal"
---@return table[] presets, string prompt_title, string skip_description
function M._presets_for_kind(kind)
  if kind == "bash" then
    return M.bash_presets, "Select Bash command pattern:", "パターンなし（Bash全体）"
  elseif kind == "path" then
    return M.path_presets, "Select path pattern:", "パターンなし（全パス）"
  elseif kind == "domain" then
    return M.domain_presets, "Select domain:", "ドメイン指定なし（全ドメイン）"
  end
  -- literal は完全一致でしか使えないため、事前定義しても再利用性がない。custom 入力だけ出す。
  return {}, "Enter pattern:", "パターンなし（全体）"
end

---パターンピッカーを表示
---@param presets table[] 選択肢のプリセット
---@param prompt_title string
---@param skip_description string 「パターンなし」の説明文
---@param callback function(pattern: string?)
function M.show_pattern_picker(presets, prompt_title, skip_description, callback)
  local preset_list = vim.tbl_map(function(preset)
    return {
      pattern = preset.pattern,
      description = preset.description,
      danger = preset.danger,
    }
  end, presets)

  table.insert(preset_list, {
    pattern = "custom",
    description = "カスタムパターンを入力...",
    danger = false,
  })

  table.insert(preset_list, {
    pattern = "skip",
    description = skip_description,
    danger = false,
  })

  local has_telescope, _ = pcall(require, "telescope")

  if has_telescope then
    M._show_pattern_telescope(preset_list, prompt_title, callback)
  else
    M._show_pattern_native(preset_list, prompt_title, callback)
  end
end

---vim.ui.selectでパターン選択
---@param preset_list table[]
---@param prompt_title string
---@param callback function(pattern: string)
function M._show_pattern_native(preset_list, prompt_title, callback)
  vim.ui.select(preset_list, {
    prompt = prompt_title,
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

---Telescopeでパターン選択
---@param preset_list table[]
---@param prompt_title string
---@param callback function(pattern: string)
function M._show_pattern_telescope(preset_list, prompt_title, callback)
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
      prompt_title = prompt_title,
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

---allow/ask/deny の選択肢を、そのツールの現在の設定付きで組み立てる
---「このツール、もう allow に入ってたっけ?」に答えられるようにするのが目的。
---引数付きのエントリ（`Bash(git:*)`）も同じツールのものとして拾う。
---@param tool_name string
---@param current_lists table {allow: string[], ask: string[], deny: string[]}
---@return table[] choices
function M.build_permission_type_choices(tool_name, current_lists)
  current_lists = current_lists or {}

  local function summarize(list)
    local matches = vim.tbl_filter(function(entry)
      return entry == tool_name or vim.startswith(entry, tool_name .. "(")
    end, list or {})
    if #matches == 0 then
      return "現在: なし"
    end
    return "現在: " .. table.concat(matches, ", ")
  end

  return {
    {
      type = "allow",
      description = string.format("Allow - このツールの使用を許可 (%s)", summarize(current_lists.allow)),
    },
    {
      type = "ask",
      description = string.format("Ask - このツールの使用前に確認を要求 (%s)", summarize(current_lists.ask)),
    },
    {
      type = "deny",
      description = string.format("Deny - このツールの使用を拒否 (%s)", summarize(current_lists.deny)),
    },
  }
end

---Allow/Ask/Deny選択プロンプト
---@param tool_name string ツール名
---@param current_lists table {allow: string[], ask: string[], deny: string[]}
---@param callback function(permission_type: string) "allow" / "ask" / "deny"
function M.prompt_permission_type(tool_name, current_lists, callback)
  local choices = M.build_permission_type_choices(tool_name, current_lists)

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

---パターン選択フロー
---引数を取れるツール（`ARG_KIND` に載っているもの）だけパターン選択を促す。
---載っていないツールに引数を付けさせないのは意図的: `matchers` が解釈できない形は
---`unknown_pattern` として黙って不一致になり、作ったルールが永久に効かなくなるため。
---@param tool table ツール情報
---@param permission_type string "allow" / "ask" / "deny"
---@param callback function(permission_string: string)
function M.handle_pattern_selection(tool, permission_type, callback)
  local kind = M.ARG_KIND[tool.name]
  if not kind then
    callback(M.build_permission_string(tool.name, nil))
    return
  end

  local presets, prompt_title, skip_description = M._presets_for_kind(kind)
  M.show_pattern_picker(presets, prompt_title, skip_description, function(pattern)
    callback(M.build_permission_string(tool.name, pattern))
  end)
end

---権限文字列を構築
---Bashだけが `Bash(git:*)` のように `:*` を付ける。パス・ドメイン・リテラルは
---`Read(src/**)` のように素の引数を括弧に入れる（`matchers.parse_tool_pattern` の分類に従う）。
---@param tool_name string ツール名
---@param pattern string? 引数パターン
---@return string permission_string
function M.build_permission_string(tool_name, pattern)
  if not pattern or pattern == "" then
    return tool_name
  end

  local kind = M.ARG_KIND[tool_name]
  if kind == "bash" then
    return string.format("%s(%s:*)", tool_name, pattern)
  elseif kind then
    return string.format("%s(%s)", tool_name, pattern)
  end

  return tool_name
end

return M
