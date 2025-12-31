---Filetype plugin for vibing chat files (.vibing)
---Sets up completion, markdown-like settings, and applies wrap configuration
---@module "ftplugin.vibing"

-- Inherit markdown settings
vim.bo.syntax = "markdown"
vim.bo.commentstring = "<!-- %s -->"

-- Set up omni-completion for slash commands
vim.bo.omnifunc = "v:lua.require'vibing.completion'.slash_command_complete"

-- Configure completion menu for slash commands
-- These options ensure the omni-completion menu displays correctly:
-- - menu: show popup menu even with one match
-- - menuone: show menu even when there's only one match
-- - noselect: don't auto-select first match (user explicitly chooses)
vim.bo.completeopt = "menu,menuone,noselect"

-- Markdown-like settings
vim.bo.textwidth = 0
vim.bo.formatoptions = "tcqj"
vim.wo.conceallevel = 2

-- Apply wrap configuration for .vibing files using BufEnter autocmd
-- This ensures wrap settings only affect vibing buffers and don't leak to other buffers
local ok, ui_utils = pcall(require, "vibing.utils.ui")
if ok then
  -- Apply immediately on first load
  ui_utils.apply_wrap_config(0)

  -- Set up autocmd for future BufEnter events
  -- This ensures wrap settings are reapplied when re-entering the vibing buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("vibing_wrap_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      ui_utils.apply_wrap_config(0)
    end,
    desc = "Apply vibing wrap settings on buffer enter"
  })
end

-- Disable spell checking by default (users can enable with :set spell)
vim.wo.spell = false
