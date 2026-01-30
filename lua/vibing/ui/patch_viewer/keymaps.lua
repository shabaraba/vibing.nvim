---@class Vibing.PatchViewer.Keymaps
local M = {}

---@param state Vibing.PatchViewer.State
---@param callbacks { select_file: fun(dir: number), select_from_cursor: fun(), cycle_window: fun(dir: number), revert: fun(), revert_all: fun(), close: fun() }
function M.setup(state, callbacks)
  if state.buf_files and vim.api.nvim_buf_is_valid(state.buf_files) then
    local opts = { buffer = state.buf_files, noremap = true, silent = true }

    vim.keymap.set("n", "j", function()
      callbacks.select_file(1)
    end, vim.tbl_extend("force", opts, { desc = "Next file" }))

    vim.keymap.set("n", "k", function()
      callbacks.select_file(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous file" }))

    vim.keymap.set("n", "<CR>", function()
      callbacks.select_from_cursor()
    end, vim.tbl_extend("force", opts, { desc = "Select file" }))

    M._setup_common(state.buf_files, callbacks)
  end

  if state.buf_diff and vim.api.nvim_buf_is_valid(state.buf_diff) then
    local opts = { buffer = state.buf_diff, noremap = true, silent = true }

    vim.keymap.set("n", "<C-j>", function()
      callbacks.select_file(1)
    end, vim.tbl_extend("force", opts, { desc = "Next file" }))

    vim.keymap.set("n", "<C-k>", function()
      callbacks.select_file(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous file" }))

    M._setup_common(state.buf_diff, callbacks)
  end
end

---@param buf number
---@param callbacks { cycle_window: fun(dir: number), revert: fun(), revert_all: fun(), close: fun() }
function M._setup_common(buf, callbacks)
  local opts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "<Tab>", function()
    callbacks.cycle_window(1)
  end, vim.tbl_extend("force", opts, { desc = "Next window" }))

  vim.keymap.set("n", "<S-Tab>", function()
    callbacks.cycle_window(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous window" }))

  vim.keymap.set("n", "r", function()
    callbacks.revert()
  end, vim.tbl_extend("force", opts, { desc = "Revert selected file" }))

  vim.keymap.set("n", "R", function()
    callbacks.revert_all()
  end, vim.tbl_extend("force", opts, { desc = "Revert all files in patch" }))

  vim.keymap.set("n", "q", function()
    callbacks.close()
  end, vim.tbl_extend("force", opts, { desc = "Close" }))

  vim.keymap.set("n", "<Esc>", function()
    callbacks.close()
  end, vim.tbl_extend("force", opts, { desc = "Close" }))
end

return M
