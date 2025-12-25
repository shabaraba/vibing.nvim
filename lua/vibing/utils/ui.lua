---UI utility functions for vibing.nvim
---@module "vibing.utils.ui"
local M = {}

---Apply wrap configuration to a window based on ui.wrap config setting.
---Reads the ui.wrap setting from config and applies it to the specified window.
---
---@param win number Window handle (use 0 for current window)
function M.apply_wrap_config(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local ok, config = pcall(require, "vibing.config")
  if not ok then
    return
  end

  local opts = config.get()
  if not opts.ui or not opts.ui.wrap then
    return
  end

  local wrap_setting = opts.ui.wrap

  if wrap_setting == "nvim" then
    -- Do nothing, respect Neovim defaults
    return
  elseif wrap_setting == "on" then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
  elseif wrap_setting == "off" then
    vim.wo[win].wrap = false
  end
end

return M
