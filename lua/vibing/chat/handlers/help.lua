local notify = require("vibing.utils.notify")
local commands = require("vibing.chat.commands")

---/helpコマンドハンドラー
---利用可能なスラッシュコマンド一覧を表示
---組み込みコマンド、プロジェクトカスタムコマンド、ユーザーカスタムコマンドを区別して表示
---@param args string[] コマンド引数（未使用）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 常にtrueを返す
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid chat buffer")
    return false
  end

  -- 全コマンドを取得してソース別に分類
  local all_commands = commands.list_all()
  local builtin = {}
  local project = {}
  local user = {}

  for name, cmd in pairs(all_commands) do
    if cmd.source == "builtin" then
      table.insert(builtin, cmd)
    elseif cmd.source == "project" then
      table.insert(project, cmd)
    elseif cmd.source == "user" then
      table.insert(user, cmd)
    end
  end

  -- 各カテゴリをアルファベット順にソート
  table.sort(builtin, function(a, b) return a.name < b.name end)
  table.sort(project, function(a, b) return a.name < b.name end)
  table.sort(user, function(a, b) return a.name < b.name end)

  -- ヘルプテキストを構築
  local lines = {
    "",
    "# Available Slash Commands",
    "",
  }

  -- 組み込みコマンド
  if #builtin > 0 then
    table.insert(lines, "## Built-in Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(builtin) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  -- プロジェクトカスタムコマンド
  if #project > 0 then
    table.insert(lines, "## Project Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(project) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  -- ユーザーカスタムコマンド
  if #user > 0 then
    table.insert(lines, "## User Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(user) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  -- バッファの最後に挿入
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count - 1, false, lines)

  notify.info("Help displayed")
  return true
end
