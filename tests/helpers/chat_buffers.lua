--- Test seam for specs that render real chat buffers.
---
--- `view` keeps rendered chats in two module-level places (`_attached_buffers` and
--- `_current_buffer`), so a spec that renders one leaks it into every spec after it in the same
--- Neovim: the next `get_chat_buffer` finds a stale entry, and `setup()` alone does not clear
--- them. Every such spec therefore needs the same reset before and the same buffer sweep after.
---
--- Shared rather than pasted per spec so a change to `view`'s bookkeeping is repaired once.
--- @module tests.helpers.chat_buffers

local M = {}

--- Point chat storage at a fresh temp directory and clear `view`'s registries.
---
--- The temp `save_dir` matters: with the default `save_location_type = "project"` these specs
--- would write real chat files into the repository checkout.
---
--- @return string save_dir the temp directory chats will be written to
function M.setup()
  local save_dir = vim.fn.tempname() .. "_chat/"
  vim.fn.mkdir(save_dir, "p")
  require("vibing").setup({ chat = { save_location_type = "custom", save_dir = save_dir } })

  M.reset()
  return save_dir
end

--- Delete every buffer `view` is tracking and empty its registries.
function M.reset()
  local view = require("vibing.presentation.chat.view")
  for bufnr, _ in pairs(view._attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  view._attached_buffers = {}
  view._current_buffer = nil
end

return M
