---@class Vibing.Presentation.ProgrammaticSender
---Programmatic message sending to chat buffers
local M = {}

local view = require("vibing.presentation.chat.view")
local Renderer = require("vibing.presentation.chat.modules.renderer")

-- Per-buffer send locks to prevent concurrent sends
local _send_locks = {}

---Programmatically send a message to a chat buffer
---@param bufnr number Buffer number
---@param message string Message content to send
---@param sender? string Sender role type (default: "User", or "mention_from", "mention_response")
---@param squad_name? string Squad name (required for "mention_from" and "mention_response")
---@return {success: boolean, bufnr: number}
function M.send(bufnr, message, sender, squad_name)
  sender = sender or "User"

  -- Validate buffer
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer number")
  end

  -- Validate message content
  if not message or vim.trim(message) == "" then
    error("Empty message")
  end

  -- Validate squad_name for mention headers
  if (sender == "mention_from" or sender == "mention_response") and not squad_name then
    error("squad_name is required for mention headers")
  end

  -- Get ChatBuffer instance via public API
  local chat_buf = view.get_chat_buffer(bufnr)
  if not chat_buf then
    error("Buffer is not a vibing chat buffer")
  end

  -- Acquire lock to prevent concurrent sends
  if _send_locks[bufnr] then
    error("Another send operation is in progress for this buffer")
  end
  _send_locks[bufnr] = true

  local success, err = pcall(function()
    -- Save and restore cursor position
    local saved_win = vim.api.nvim_get_current_win()
    local saved_cursor = vim.api.nvim_win_is_valid(saved_win)
      and vim.api.nvim_win_get_cursor(saved_win)
      or nil

    -- Add section based on sender type
    if sender == "mention_from" or sender == "mention_response" then
      Renderer.addMentionSection(bufnr, sender, squad_name, message)
    else
      -- Legacy: User section
      Renderer.addUserSection(bufnr, nil, nil, nil, message)
    end

    chat_buf:send_message()

    -- Restore cursor
    if saved_cursor and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_win_set_cursor, saved_win, saved_cursor)
    end
  end)

  -- Release lock
  _send_locks[bufnr] = nil

  if not success then
    error(string.format("Failed to send message: %s", tostring(err)))
  end

  return { success = true, bufnr = bufnr }
end

return M
