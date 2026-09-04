---@class Vibing.Application.Chat.UseCases.CarryOver
---いま書いてある未送信メッセージだけを持って新しいチャットを始める Use Case。
---
---handoff との違いは要約を作らないこと。要約の生成そのものが会話全体を1リクエストで読み直す
---呼び出しなので、「キャッシュが切れているから移る」場面ではそれを避けることが目的そのものに
---なる（`application/chat/cache_expiry`）。文脈ごと持っていきたいときは `:VibingChatHandoff`
---を使う経路が別にあり、`### Tokens` の警告文がそれを案内している。
---
---frontmatter・ファイル名・書き出し・元チャットの保存は handoff と同じ `continuation_chat`。
local M = {}

local ContinuationChat = require("vibing.application.chat.use_cases.continuation_chat")
local Timestamp = require("vibing.core.utils.timestamp")

---元チャットの未送信セクションを空にする。
---
---残すと同じ本文が2つのチャットに並び、どちらが「これから送るもの」か分からなくなる。
---ヘッダー自体は残すので、元のチャットはそのまま次の入力を受けられる
---@param buf number
function M.clear_unsent_body(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    if Timestamp.is_unsent_header(lines[i]) then
      vim.api.nvim_buf_set_lines(buf, i, #lines, false, { "" })
      return
    end
  end
end

---未送信本文を引き継いだ新しいチャットセッションを作る（同期）。
---@param chat_buffer Vibing.ChatBuffer 引き継ぎ元
---@param message string 引き継ぐ未送信本文
---@return Vibing.ChatSession? session
---@return string? error
function M.execute(chat_buffer, message)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    return nil, "No valid chat buffer to continue from"
  end
  if type(message) ~= "string" or vim.trim(message) == "" then
    return nil, "There is no unsent message to carry over"
  end

  local session, err = ContinuationChat.create(chat_buffer, { body = message, suffix = "continued" })
  if not session then
    return nil, err
  end

  M.clear_unsent_body(chat_buffer.buf)
  ContinuationChat.save_source(chat_buffer.buf)
  return session
end

return M
