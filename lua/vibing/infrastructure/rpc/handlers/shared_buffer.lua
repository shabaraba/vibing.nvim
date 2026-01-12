---Shared buffer RPC handlers for vibing.nvim
local M = {}

---Check if current session has unprocessed mentions
---@param params table RPC parameters
---@return table result { has_mentions: boolean, count: number, claude_id?: string }
function M.has_unprocessed_mentions(params)
  -- Get active ChatBuffer from chat controller
  local chat_controller = require("vibing.presentation.chat.controller")
  local chat_buffer = chat_controller.get_active_chat_buffer()

  if not chat_buffer then
    return {
      has_mentions = false,
      count = 0,
    }
  end

  local has_mentions = chat_buffer:has_unprocessed_mentions()
  local mentions = chat_buffer:get_unprocessed_mentions()

  return {
    has_mentions = has_mentions,
    count = #mentions,
    claude_id = chat_buffer:get_claude_id(),
  }
end

---Get list of unprocessed mentions
---@param params table RPC parameters
---@return table result { mentions: MentionRecord[] }
function M.get_unprocessed_mentions(params)
  local chat_controller = require("vibing.presentation.chat.controller")
  local chat_buffer = chat_controller.get_active_chat_buffer()

  if not chat_buffer then
    return {
      mentions = {},
    }
  end

  local mentions = chat_buffer:get_unprocessed_mentions()

  return {
    mentions = mentions,
  }
end

return M
