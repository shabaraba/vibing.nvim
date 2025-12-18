local notify = require("vibing.utils.notify")

---@class Vibing.SlashCommand
---チャット内で使用可能なスラッシュコマンドの定義
---@field name string コマンド名（/の後に入力する文字列、例: "context", "clear"）
---@field handler fun(args: string[], chat_buffer: Vibing.ChatBuffer): boolean ハンドラー関数（引数とバッファを受け取り成功/失敗を返す）
---@field description string コマンドの説明文（/helpで表示される）

---@class Vibing.CommandRegistry
---チャットコマンドレジストリ
---スラッシュコマンドの登録、パース、実行を管理
local M = {}

---登録済みコマンドのマップ（コマンド名 → SlashCommandオブジェクト）
---@type table<string, Vibing.SlashCommand>
M.commands = {}

---新しいスラッシュコマンドを登録
---chat/init.luaから組み込みコマンドの登録に使用される
---同名のコマンドが既に存在する場合は上書き
---@param command Vibing.SlashCommand 登録するコマンド（name, handler, description）
function M.register(command)
  M.commands[command.name] = command
end

---メッセージがスラッシュコマンドかどうかを判定
---先頭が/で始まり、その後に単語文字（\w+）が続く場合にtrueを返す
---@param message string チェックするメッセージ文字列
---@return boolean メッセージがスラッシュコマンドの形式ならtrue
function M.is_command(message)
  return message:match("^/%w+") ~= nil
end

---メッセージからコマンド名と引数を抽出
---例: "/context foo.lua" → ("context", {"foo.lua"})
---先頭の/を削除してスペースで分割し、最初の要素をコマンド名、残りを引数とする
---@param message string パースするメッセージ文字列
---@return string? command_name コマンド名（コマンドでない場合はnil）
---@return string[] args コマンド引数の配列（空配列の場合あり）
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

---スラッシュコマンドを実行
---メッセージをパースし、登録済みハンドラーを呼び出す
---未登録のコマンドの場合は警告を表示
---ハンドラー実行中のエラーはpcallでキャッチして通知
---@param message string 実行するコマンド文字列（例: "/context foo.lua"）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行するチャットバッファ
---@return boolean handled コマンドとして処理された場合true（成功/失敗問わず）、コマンド形式でない場合false
function M.execute(message, chat_buffer)
  local command_name, args = M.parse(message)

  if not command_name then
    return false
  end

  local command = M.commands[command_name]
  if not command then
    notify.warn(string.format("Unknown command: /%s", command_name))
    return true -- コマンドとして認識されたが存在しない
  end

  -- コマンドハンドラーを実行
  local success, result = pcall(command.handler, args, chat_buffer)
  if not success then
    notify.error(string.format("Command error: %s", result))
  end

  return true
end

---登録済みコマンドの一覧を取得
---コマンド名でソート済みの配列を返す
---/helpコマンドでの一覧表示に使用
---@return Vibing.SlashCommand[] コマンド名でソートされたコマンドオブジェクトの配列
function M.list()
  local list = {}
  for _, command in pairs(M.commands) do
    table.insert(list, command)
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

return M
