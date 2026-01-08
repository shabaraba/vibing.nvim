local M = {}

-- Execute a Vim command supplied in params.command.
-- @param params Table containing the invocation parameters. Must include the field `command` (string) with the Vim command to execute.
-- @return A table with `success = true` and `output` field containing the command output (if any).
-- @throws If `params` is nil or `params.command` is nil, raises an error: "Missing command parameter".
function M.execute(params)
  local cmd = params and params.command
  if not cmd then
    error("Missing command parameter")
  end

  -- Use nvim_exec2 to capture output and avoid blocking on user input
  local ok, result = pcall(vim.api.nvim_exec2, cmd, { output = true })

  if not ok then
    error(string.format("Command execution failed: %s", result))
  end

  return {
    success = true,
    output = result.output or "",
  }
end

return M
