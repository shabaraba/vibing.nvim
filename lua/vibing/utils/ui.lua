---UI utility functions for vibing.nvim
---@module "vibing.utils.ui"

---@diagnostic disable-next-line: undefined-global
local vim = vim
local M = {}

---Apply wrap configuration to a window based on ui.wrap config setting.
---Reads the ui.wrap setting from config and applies it to the specified window.
---
---@param win number Window handle (use 0 for current window)
---@return nil
function M.apply_wrap_config(win)
  -- Validate window handle
  if not win or not vim.api.nvim_win_is_valid(win) then
    if vim.log and vim.log.levels then
      vim.notify(
        string.format("apply_wrap_config: invalid window handle (%s)", tostring(win)),
        vim.log.levels.DEBUG
      )
    end
    return
  end

  -- Load config module
  local ok, config = pcall(require, "vibing.config")
  if not ok then
    if vim.log and vim.log.levels then
      vim.notify(
        string.format("apply_wrap_config: failed to load config: %s", tostring(config)),
        vim.log.levels.DEBUG
      )
    end
    return
  end

  -- Get config options
  local opts = config.get()
  if not opts.ui or not opts.ui.wrap then
    if vim.log and vim.log.levels then
      vim.notify("apply_wrap_config: ui.wrap not configured", vim.log.levels.DEBUG)
    end
    return
  end

  ---@type "nvim"|"on"|"off"
  local wrap_setting = opts.ui.wrap

  if wrap_setting == "nvim" then
    -- Do nothing, respect Neovim defaults
    if vim.log and vim.log.levels then
      vim.notify("apply_wrap_config: using Neovim defaults", vim.log.levels.DEBUG)
    end
    return
  elseif wrap_setting == "on" then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    if vim.log and vim.log.levels then
      vim.notify(
        string.format("apply_wrap_config: enabled wrap for window %d", win),
        vim.log.levels.DEBUG
      )
    end
  elseif wrap_setting == "off" then
    vim.wo[win].wrap = false
    if vim.log and vim.log.levels then
      vim.notify(
        string.format("apply_wrap_config: disabled wrap for window %d", win),
        vim.log.levels.DEBUG
      )
    end
  end
end

return M
