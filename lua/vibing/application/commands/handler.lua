---@class Vibing.Application.CommandHandler
---スラッシュコマンドハンドラー
local M = {}

local notify = require("vibing.core.utils.notify")

---@type table<string, function>
M.handlers = {}

---コマンドを登録
---@param name string
---@param handler function
function M.register(name, handler)
  M.handlers[name] = handler
end

---コマンドを実行
---@param command string
---@param args string[]
---@param chat_buffer table
---@return boolean handled
function M.execute(command, args, chat_buffer)
  local handler = M.handlers[command]
  if handler then
    handler(args, chat_buffer)
    return true
  end
  return false
end

---コマンドが存在するか確認
---@param command string
---@return boolean
function M.exists(command)
  return M.handlers[command] ~= nil
end

---登録済みコマンド一覧を取得
---@return string[]
function M.list()
  return vim.tbl_keys(M.handlers)
end

---ビルトインコマンドを初期化
function M.init_builtin()
  -- /context
  M.register("context", function(args, chat_buffer)
    local Context = require("vibing.application.context.manager")
    if #args > 0 then
      Context.add(args[1])
    else
      Context.add()
    end
  end)

  -- /clear
  M.register("clear", function(args, chat_buffer)
    local Context = require("vibing.application.context.manager")
    Context.clear()
  end)

  -- /save
  M.register("save", function(args, chat_buffer)
    if chat_buffer then
      chat_buffer:save()
    end
  end)

  -- /mode
  M.register("mode", function(args, chat_buffer)
    if #args == 0 then
      notify.info("Usage: /mode <auto|plan|code|explore>", "Chat")
      return
    end
    if chat_buffer then
      chat_buffer:set_mode(args[1])
    end
  end)

  -- /model
  M.register("model", function(args, chat_buffer)
    if #args == 0 then
      notify.info("Usage: /model <opus|sonnet|haiku>", "Chat")
      return
    end
    if chat_buffer then
      chat_buffer:set_model(args[1])
    end
  end)
end

return M
