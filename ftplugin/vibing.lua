---Filetype plugin for vibing chat files (.vibing)
---Sets up completion, markdown-like settings, and applies wrap configuration
---@module "ftplugin.vibing"

-- Inherit markdown settings
vim.bo.syntax = "markdown"
vim.bo.commentstring = "<!-- %s -->"

-- Set up completion for vibing buffers
-- Uses new completion module with nvim-cmp support and omnifunc fallback
-- Note: setup_buffer may not exist if vibing.setup() hasn't been called yet
local ok, completion = pcall(require, "vibing.application.completion")
if ok and completion.setup_buffer then
  pcall(completion.setup_buffer, vim.api.nvim_get_current_buf())
elseif ok then
  -- Module loaded but setup_buffer not ready - use omnifunc directly
  pcall(function()
    vim.bo.omnifunc = "v:lua.require('vibing.application.completion').omnifunc"
    vim.bo.completeopt = "menu,menuone,noselect"
  end)
end

-- Configure nvim-cmp for vibing buffers (merge vibing source with user's existing sources)
local has_cmp, cmp = pcall(require, "cmp")
if has_cmp then
  -- Ensure vibing source is registered first
  local ok_completion, completion_module = pcall(require, "vibing.application.completion")
  if ok_completion then
    completion_module.setup()
  end

  -- Get user's existing sources and merge with vibing source
  local global_config = cmp.get_config()
  local existing_sources = global_config.sources or {}

  -- Build merged sources: vibing first, then user's sources (excluding duplicate vibing)
  local merged_sources = {
    { name = "vibing", priority = 1000 },
  }
  for _, source in ipairs(existing_sources) do
    if source.name ~= "vibing" then
      table.insert(merged_sources, source)
    end
  end

  cmp.setup.buffer({
    sources = merged_sources,
  })
end

-- Markdown-like settings
vim.bo.textwidth = 0
vim.bo.formatoptions = "tcqj"
vim.wo.conceallevel = 2

-- Apply wrap configuration for .vibing files using BufEnter autocmd
-- This ensures wrap settings only affect vibing buffers and don't leak to other buffers
local ok, ui_utils = pcall(require, "vibing.core.utils.ui")
if ok then
  -- Apply immediately on first load
  pcall(ui_utils.apply_wrap_config, 0)

  -- Set up autocmd for future BufEnter events
  -- This ensures wrap settings are reapplied when re-entering the vibing buffer
  -- Use shared group name to avoid accumulating group names in memory
  local bufnr = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("vibing_wrap", { clear = false })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      pcall(ui_utils.apply_wrap_config, 0)
    end,
    desc = "Apply vibing wrap settings on buffer enter",
  })
end

-- Clean up running processes when buffer is unloaded
-- This prevents "Job still running" errors when closing Neovim
local bufnr = vim.api.nvim_get_current_buf()
local group = vim.api.nvim_create_augroup("vibing_cleanup", { clear = false })

vim.api.nvim_create_autocmd("BufUnload", {
  group = group,
  buffer = bufnr,
  callback = function()
    -- Get the ChatBuffer instance for this buffer
    local ok_view, view = pcall(require, "vibing.presentation.chat.view")
    if not ok_view then
      return
    end

    local chat_buf = view._attached_buffers[bufnr] or (view._current_buffer and view._current_buffer.buf == bufnr and view._current_buffer)
    if chat_buf and chat_buf._current_handle_id then
      local ok_vibing, vibing = pcall(require, "vibing")
      if ok_vibing then
        local adapter = vibing.get_adapter()
        if adapter then
          adapter:cancel(chat_buf._current_handle_id)
        end
      end
    end
  end,
  desc = "Cancel running Agent SDK process on buffer unload",
})

-- Disable spell checking by default (users can enable with :set spell)
vim.wo.spell = false
