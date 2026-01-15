---@class Vibing.Application.Mention.Notifier
---メンション通知サービス
---宛先Squadが停止中の場合に通知を挿入してリクエストを送信
local M = {}

---宛先Squadにメンション通知を送信
---@param to_squad_name string 宛先Squad名
---@param from_squad_name string 送信元Squad名
---@param content string メンション内容
---@return boolean notified 通知が送信されたかどうか
function M.notify_if_idle(to_squad_name, from_squad_name, content)
  local Registry = require("vibing.infrastructure.squad.registry")
  local view = require("vibing.presentation.chat.view")
  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

  -- 宛先バッファを取得
  local target_bufnr = Registry.find_buffer(to_squad_name)
  if not target_bufnr then
    return false
  end

  -- ChatBufferインスタンスを取得
  local chat_buffer = view.get_chat_buffer(target_bufnr)
  if not chat_buffer then
    return false
  end

  -- 実行中かどうかを判定
  if chat_buffer._current_handle_id then
    -- Agent実行中 → canUseToolで中断されるので何もしない
    return false
  end

  -- Agent停止中 → 通知メッセージを送信
  local message = M.build_notification_message(from_squad_name, content)

  local ok, err = pcall(function()
    ProgrammaticSender.send(target_bufnr, message, "User")
  end)

  if not ok then
    vim.notify(
      string.format("[vibing] Failed to send mention notification: %s", tostring(err)),
      vim.log.levels.WARN
    )
    return false
  end

  return true
end

---通知メッセージを構築
---@param from_squad_name string 送信元Squad名
---@param content string メンション内容
---@return string message
function M.build_notification_message(from_squad_name, content)
  local lines = {
    string.format("📢 **@%s** mentioned you:", from_squad_name),
    "",
    "> " .. content:gsub("\n", "\n> "),
    "",
    "Please respond to this mention using `/check-mentions` or reply directly.",
  }
  return table.concat(lines, "\n")
end

return M
