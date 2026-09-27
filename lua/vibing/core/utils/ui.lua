---UI utility functions for vibing.nvim
---@module "vibing.core.utils.ui"

---@diagnostic disable-next-line: undefined-global
local vim = vim
local config = require("vibing.config")
local M = {}

---Check if a buffer is a vibing chat buffer
---@param bufnr number Buffer number
---@return boolean True if the buffer is a vibing chat buffer
local function is_chat_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- Use existing Frontmatter module to check if buffer is a vibing chat
  local ok, Frontmatter = pcall(require, "vibing.infrastructure.storage.frontmatter")
  if not ok then
    return false
  end

  return Frontmatter.is_vibing_chat_buffer(bufnr)
end

---Apply wrap configuration to a window based on ui.wrap config setting.
---Only applies to vibing chat buffers. Other buffers follow normal Neovim settings.
---
---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (optional, will be detected from window if not provided)
---@param force? boolean Force apply wrap settings even if is_chat_buffer() returns false (for newly created chat buffers)
---@return nil
function M.apply_wrap_config(win, bufnr, force)
  -- Validate window handle (0 means current window, which is valid)
  if type(win) ~= "number" then
    return
  end
  if win ~= 0 and not vim.api.nvim_win_is_valid(win) then
    return
  end

  -- Get buffer number if not provided
  if not bufnr then
    if win == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    else
      bufnr = vim.api.nvim_win_get_buf(win)
    end
  end

  -- Get config options
  local opts = config.get()
  if not opts.ui or not opts.ui.wrap then
    return
  end

  ---@type "nvim"|"on"|"off"
  local wrap_setting = opts.ui.wrap

  -- Check if this is a chat buffer
  local is_chat = force or is_chat_buffer(bufnr)

  if wrap_setting == "nvim" then
    -- Do nothing, respect Neovim defaults
    return
  elseif wrap_setting == "on" and is_chat then
    -- Apply wrap for chat buffers
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("linebreak", true, { win = win, scope = "local" })
  else
    -- Reset to global default (opt.wrap = false) for non-chat buffers
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
  end
end

---In order, because switching the method first would evaluate the window's previous `foldexpr`
---over the whole buffer, and `foldlevel` decides the state of folds that must already exist.
---@type { [1]: string, [2]: string|boolean|number }[]
local FOLD_OPTIONS = {
  { "foldexpr", "v:lua.require'vibing.infrastructure.treesitter_fold'.foldexpr(v:lnum)" },
  { "foldmethod", "expr" },
  { "foldenable", true },
  { "foldlevel", 0 },
}

---Start a chat window's rendered tool calls and reasoning folded, so it opens on the answer.
---
---Only ever writes to a window showing a chat. Neovim keeps window-local options per
---window+buffer pair (measured: a window set to `foldmethod=expr` on a chat is back to `manual`
---on the next buffer and `expr` again on return), so nothing has to be reset afterwards and the
---user's own fold settings on their code windows are never touched.
---
---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (detected from the window when omitted)
---@param force? boolean Treat the buffer as a chat even before it has frontmatter
---@return nil
function M.apply_fold_config(win, bufnr, force)
  if type(win) ~= "number" then
    return
  end
  if win ~= 0 and not vim.api.nvim_win_is_valid(win) then
    return
  end

  if not bufnr then
    bufnr = win == 0 and vim.api.nvim_get_current_buf() or vim.api.nvim_win_get_buf(win)
  end

  local opts = config.get()
  local fold = opts.ui and opts.ui.fold
  if not fold or fold.enabled ~= true then
    return
  end

  if not (force or is_chat_buffer(bufnr)) then
    return
  end

  -- `queries/vibing/folds.scm` names nodes only the outer parser produces, so under the Markdown
  -- fallback there is nothing to fold and the window would get `foldmethod=expr` for nothing.
  local ok_ts, treesitter = pcall(require, "vibing.infrastructure.treesitter")
  if not ok_ts or not treesitter.is_outer_parser_available() then
    return
  end

  for _, option in ipairs(FOLD_OPTIONS) do
    vim.api.nvim_set_option_value(option[1], option[2], { win = win, scope = "local" })
  end
end

---Apply every window-local setting a vibing chat window gets.
---
---The one entry point, so a new setting reaches all four places a chat window is resolved
---(creation, attach, `FileType`, `WinEnter`) instead of three of them.
---
---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (detected from the window when omitted)
---@param force? boolean Treat the buffer as a chat even before it has frontmatter
---@return nil
function M.apply_window_config(win, bufnr, force)
  M.apply_wrap_config(win, bufnr, force)
  M.apply_fold_config(win, bufnr, force)
end

return M
