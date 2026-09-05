---@class Vibing.Application.Chat.BufferTail
---Read only the tail of a **live** buffer's last `## ...` section, growing a backward-read chunk
---until a header turns up (or the chunk covers the whole buffer) instead of reading the whole
---thing. A vibing.nvim chat can run to hundreds of thousands of lines (#694), so this is the one
---place that talks to `vim.api.nvim_buf_*` for that read — `domain/chat/buffer_window.lua` windows
---an already-read line array and deliberately never touches a live buffer.
---
---Shared by `nvim_get_buffer` (`infrastructure/rpc/handlers/buffer.lua`) and the orchestration
---"stopped without report" notification (`application/chat/completion_notifier.lua`, #693), so the
---two callers cannot drift on what "the tail of the last section" means.
local M = {}

local BufferWindow = require("vibing.domain.chat.buffer_window")

---@param bufnr number
---@param tail_lines integer? Already normalized by `BufferWindow.normalize_tail_lines`.
---@return string[] windowed
---@return integer total_lines
function M.read_last_section(bufnr, tail_lines)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local chunk_size = 500
  local chunk, from

  repeat
    from = math.max(0, total_lines - chunk_size)
    chunk = vim.api.nvim_buf_get_lines(bufnr, from, total_lines, false)
    chunk_size = chunk_size * 2
  until BufferWindow.find_last_header(chunk) or from == 0

  local windowed = BufferWindow.slice(chunk, { tail_lines = tail_lines, last_section = true })
  return windowed, total_lines
end

return M
