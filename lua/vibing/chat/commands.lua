---@class Vibing.SlashCommand
---@field name string
---@field handler fun(args: string[], chat_buffer: Vibing.ChatBuffer): boolean
---@field description string

---@class Vibing.CommandRegistry
local M = {}

---@type table<string, Vibing.SlashCommand>
M.commands = {}

---コマンドを登録
---@param command Vibing.SlashCommand
function M.register(command)
  M.commands[command.name] = command
end

---メッセージがスラッシュコマンドかチェック
---@param message string
---@return boolean
function M.is_command(message)
  return message:match("^/%w+") ~= nil
end

---コマンドをパース
---@param message string
---@return string? command_name, string[] args
function M.parse(message)
  -- 先頭の/を削除してスペースで分割
  local trimmed = vim.trim(message)
  if not trimmed:match("^/") then
    return nil, {}
  end

  -- /commandとそれ以降を分離
  local parts = vim.split(trimmed:sub(2), "%s+", { trimempty = true })
  if #parts == 0 then
    return nil, {}
  end

  local command_name = parts[1]
  local args = {}
  for i = 2, #parts do
    table.insert(args, parts[i])
  end

  return command_name, args
end

---コマンドを実行
---@param message string
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled コマンドが処理されたかどうか
function M.execute(message, chat_buffer)
  local command_name, args = M.parse(message)

  if not command_name then
    return false
  end

  local command = M.commands[command_name]
  if not command then
    vim.notify(
      string.format("[vibing] Unknown command: /%s", command_name),
      vim.log.levels.WARN
    )
    return true -- コマンドとして認識されたが存在しない
  end

  -- コマンドハンドラーを実行
  local success, result = pcall(command.handler, args, chat_buffer)
  if not success then
    vim.notify(
      string.format("[vibing] Command error: %s", result),
      vim.log.levels.ERROR
    )
  end

  return true
end

---利用可能なコマンド一覧を取得
---@return Vibing.SlashCommand[]
function M.list()
  local list = {}
  for _, command in pairs(M.commands) do
    table.insert(list, command)
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

return M
