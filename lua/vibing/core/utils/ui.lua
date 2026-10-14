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

---Answer the two questions every window-local setting starts from: is this a window that may be
---written to, and is it showing a chat.
---
---Resolved once per entry point rather than per setting. `is_chat_buffer` caches only its positive
---results, so on an ordinary file that opens with `---` and never closes it is a 0.5ms frontmatter
---scan -- and `apply_window_config` is the `WinEnter` handler for every window in the editor.
---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (detected from the window when omitted)
---@param force? boolean Treat the buffer as a chat even before it has frontmatter
---@return number? win nil when the handle names no window that can be written to
---@return boolean is_chat
local function resolve_window(win, bufnr, force)
  -- 0 means the current window, which is valid.
  if type(win) ~= "number" then
    return nil, false
  end
  if win ~= 0 and not vim.api.nvim_win_is_valid(win) then
    return nil, false
  end
  if force then
    return win, true
  end

  if not bufnr then
    bufnr = win == 0 and vim.api.nvim_get_current_buf() or vim.api.nvim_win_get_buf(win)
  end
  return win, is_chat_buffer(bufnr)
end

---@param win number
---@param is_chat boolean
local function apply_wrap(win, is_chat)
  local opts = config.get()
  if not opts.ui or not opts.ui.wrap then
    return
  end

  ---@type "nvim"|"on"|"off"
  local wrap_setting = opts.ui.wrap

  if wrap_setting == "nvim" then
    -- Do nothing, respect Neovim defaults
    return
  elseif wrap_setting == "on" and is_chat then
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("linebreak", true, { win = win, scope = "local" })
  else
    -- Reset to global default (opt.wrap = false) for non-chat buffers
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
  end
end

---Start a chat window's rendered tool calls and reasoning folded, so it opens on the answer.
---
---Only ever writes to a window showing a chat. Neovim keeps window-local options per
---window+buffer pair (measured: a window set to `foldmethod=expr` on a chat is back to `manual`
---on the next buffer and `expr` again on return), so nothing has to be reset afterwards and the
---user's own fold settings on their code windows are never touched.
---@param win number
---@param is_chat boolean
local function apply_fold(win, is_chat)
  if not is_chat then
    return
  end

  local opts = config.get()
  local fold = opts.ui and opts.ui.fold
  if not fold or fold.enabled ~= true then
    return
  end

  -- `queries/vibing/folds.scm` names nodes only the outer parser produces, so under the Markdown
  -- fallback there is nothing to fold and the window would get `foldmethod=expr` for nothing.
  local ok_ts, treesitter = pcall(require, "vibing.infrastructure.treesitter")
  if not ok_ts or not treesitter.is_outer_parser_available() then
    return
  end

  local ok_fold, Fold = pcall(require, "vibing.infrastructure.treesitter_fold")
  if not ok_fold then
    return
  end

  -- `WinEnter` comes back to windows that are already configured, and re-applying is not free:
  -- setting `foldlevel` sweeps the whole buffer (measured: 19.9ms and 16,805 `foldexpr`
  -- evaluations on a 16,805-line chat) and closes every fold the user had opened with `zo`. The
  -- per window+buffer storage above is what makes finding our own `foldexpr` here conclusive.
  if vim.api.nvim_get_option_value("foldexpr", { win = win, scope = "local" }) == Fold.EXPR then
    return
  end

  -- In order, because switching the method first would evaluate the window's previous `foldexpr`
  -- over the whole buffer, and `foldlevel` decides the state of folds that must already exist.
  vim.api.nvim_set_option_value("foldexpr", Fold.EXPR, { win = win, scope = "local" })
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = win, scope = "local" })
  vim.api.nvim_set_option_value("foldenable", true, { win = win, scope = "local" })
  vim.api.nvim_set_option_value("foldlevel", 0, { win = win, scope = "local" })
end

---Apply wrap configuration to a window based on ui.wrap config setting.
---Only applies to vibing chat buffers. Other buffers follow normal Neovim settings.
---
---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (optional, will be detected from window if not provided)
---@param force? boolean Force apply wrap settings even if is_chat_buffer() returns false (for newly created chat buffers)
---@return nil
function M.apply_wrap_config(win, bufnr, force)
  local resolved, is_chat = resolve_window(win, bufnr, force)
  if resolved then
    apply_wrap(resolved, is_chat)
  end
end

---@param win number Window handle (use 0 for current window)
---@param bufnr? number Buffer number (detected from the window when omitted)
---@param force? boolean Treat the buffer as a chat even before it has frontmatter
---@return nil
function M.apply_fold_config(win, bufnr, force)
  local resolved, is_chat = resolve_window(win, bufnr, force)
  if resolved then
    apply_fold(resolved, is_chat)
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
  local resolved, is_chat = resolve_window(win, bufnr, force)
  if not resolved then
    return
  end
  apply_wrap(resolved, is_chat)
  apply_fold(resolved, is_chat)
end

return M
