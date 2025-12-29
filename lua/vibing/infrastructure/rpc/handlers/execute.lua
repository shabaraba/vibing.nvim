local M = {}

-- Execute a Vim command supplied in params.command.
-- @param params Table containing the invocation parameters. Must include the field `command` (string) with the Vim command to execute.
-- @return A table with `success = true` when the command was executed.
-- @throws If `params` is nil or `params.command` is nil, raises an error: "Missing command parameter".
function M.execute(params)
  local cmd = params and params.command
  if not cmd then
    error("Missing command parameter")
  end
  vim.cmd(cmd)
  return { success = true }
end

return M
