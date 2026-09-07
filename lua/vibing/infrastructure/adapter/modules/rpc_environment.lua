--- Bind a CLI child process to the Neovim instance that launched it.
local M = {}

M.PORT_VAR = "VIBING_NVIM_RPC_PORT"

---@param env table<string, string>
function M.bind(env)
  local port = require("vibing.infrastructure.rpc.server").get_port()
  if not port then
    return
  end

  local value = tostring(port)
  env[M.PORT_VAR] = value
  env.VIBING_NVIM_CONTEXT = "true"
end

return M
