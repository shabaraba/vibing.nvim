local M = {}

function M.execute(params)
  local cmd = params and params.command
  if not cmd then
    error("Missing command parameter")
  end
  vim.cmd(cmd)
  return { success = true }
end

return M
