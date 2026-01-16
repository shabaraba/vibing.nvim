---@class Vibing.Application.Mention.Notifier
---メンション通知サービス
---宛先Squadが停止中の場合、宛先Squadのバッファに通知を送信して起動
local M = {}

---宛先Squadが停止中の場合、宛先Squadのバッファに通知を送信
---通知を受け取った宛先Squadは、メンション元のバッファに返信する
---@param to_squad_name string メンション先Squad名（通知を受け取るSquad）
---@param from_squad_name string メンション元Squad名（メンションを送ったSquad）
---@param from_bufnr number メンション元のバッファ番号（返信先）
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

  -- Agent停止中 → 宛先Squadのバッファに通知を送信して起動
  local message = M.build_notification_message(from_squad_name, from_bufnr, content)

  local ok, err = pcall(function()
    -- メンション先Squadのバッファに通知を送信
    -- Squadが起動し、from_bufnr（メンション元）のバッファに返信する
    ProgrammaticSender.send(to_bufnr, message, "User")
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
---メンション先Squadが受け取り、メンション元のバッファに返信するための指示を含む
---@param from_squad_name string メンション元Squad名
---@param from_bufnr number メンション元のバッファ番号
---@param content string メンション内容
---@return string message
function M.build_notification_message(from_squad_name, from_bufnr, content)
  -- メンション行からメッセージ本文を抽出（@SquadName の後の部分）
  local message_text = content:match("^@%w+%s+(.+)") or ""

  local lines = {
    string.format("Received mention from %s (buffer %d):", from_squad_name, from_bufnr),
    string.format("> %s", message_text),
    "",
    string.format("Please reply to buffer %d (use mcp__vibing-nvim__nvim_chat_send_message with bufnr=%d).", from_bufnr, from_bufnr),
  }
  return table.concat(lines, "\n")
end

return M
