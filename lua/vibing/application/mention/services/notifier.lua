---@class Vibing.Application.Mention.Notifier
---メンション通知サービス
---宛先Squadが停止中の場合、メンション元バッファに返信を送信
local M = {}

---宛先Squadが停止中の場合、メンション元バッファに通知を送信
---@param to_squad_name string メンション先Squad名（通知を受け取るSquad）
---@param from_squad_name string メンション元Squad名（メンションを送ったSquad）
---@param from_bufnr number メンション元のバッファ番号
---@param content string メンション内容
---@return boolean notified 通知が送信されたかどうか
function M.notify_if_idle(to_squad_name, from_squad_name, from_bufnr, content)
  local Registry = require("vibing.infrastructure.squad.registry")
  local view = require("vibing.presentation.chat.view")
  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

  -- メンション先Squadのバッファを取得
  local to_bufnr = Registry.find_buffer(to_squad_name)
  if not to_bufnr then
    return false
  end

  -- メンション先ChatBufferインスタンスを取得
  local to_chat_buffer = view.get_chat_buffer(to_bufnr)
  if not to_chat_buffer then
    return false
  end

  -- 実行中かどうかを判定
  if to_chat_buffer._current_handle_id then
    -- Agent実行中 → canUseToolで中断されるので何もしない
    return false
  end

  -- Agent停止中 → メンション元のバッファに返信を送信
  local message = M.build_reply_message(from_squad_name, content)

  local ok, err = pcall(function()
    -- メンション元のバッファに、メンション先Squadからの返信として送信
    ProgrammaticSender.send(from_bufnr, message, "User")
  end)

  if not ok then
    vim.notify(
      string.format("[vibing] Failed to send mention reply: %s", tostring(err)),
      vim.log.levels.WARN
    )
    return false
  end

  return true
end

---返信メッセージを構築
---@param from_squad_name string メンション元Squad名
---@param content string メンション内容
---@return string message
function M.build_reply_message(from_squad_name, content)
  local lines = {
    string.format("Received mention from @%s. Responding to the request:", from_squad_name),
  }
  return table.concat(lines, "\n")
end

return M
