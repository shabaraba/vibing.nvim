---Neovim remote control via --server socket
---@class Vibing.Remote
local M = {}
local notify = require("vibing.utils.notify")

---@type string?
M.socket_path = nil

---Initialize remote control with socket path
---@param socket_path? string
function M.setup(socket_path)
  if socket_path then
    M.socket_path = socket_path
  else
    -- Auto-detect from environment variable
    M.socket_path = vim.env.NVIM
  end
end

---Check if remote control is available
---@return boolean
function M.is_available()
  return M.socket_path ~= nil and M.socket_path ~= ""
end

---Send keys to remote Neovim instance
---@param keys string
---@return boolean success
function M.send(keys)
  if not M.is_available() then
    notify.error("Remote control not available. Set socket_path or start nvim with --listen", "Remote")
    return false
  end

  local cmd = string.format('nvim --server "%s" --remote-send "%s"', M.socket_path, keys)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    notify.error("Remote send failed: " .. result, "Remote")
    return false
  end

  return true
end

---Evaluate expression in remote Neovim instance
---@param expr string
---@return string? result
function M.expr(expr)
  if not M.is_available() then
    notify.error("Remote control not available", "Remote")
    return nil
  end

  local cmd = string.format('nvim --server "%s" --remote-expr "%s"', M.socket_path, expr)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    notify.error("Remote expr failed: " .. result, "Remote")
    return nil
  end

  return vim.trim(result)
end

---Execute command in remote Neovim instance
---@param command string
---@return boolean success
function M.execute(command)
  -- Escape special characters
  command = command:gsub('"', '\\"')
  return M.send(string.format(':%s<CR>', command))
end

---Get current buffer content from remote instance
---@return string[]? lines
function M.get_buffer()
  local result = M.expr('getline(1, "$")')
  if not result then
    return nil
  end

  -- Parse Vim list format: ['line1', 'line2', ...]
  local lines = {}
  for line in result:gmatch("'([^']*)'") do
    table.insert(lines, line)
  end

  return lines
end

---Get remote Neovim status
---@return table? status
function M.get_status()
  if not M.is_available() then
    return nil
  end

  local mode = M.expr('mode()')
  local bufname = M.expr('bufname("%")')
  local line = M.expr('line(".")')
  local col = M.expr('col(".")')

  if not mode then
    return nil
  end

  return {
    mode = mode,
    bufname = bufname or "",
    line = tonumber(line) or 0,
    col = tonumber(col) or 0,
  }
end

return M
