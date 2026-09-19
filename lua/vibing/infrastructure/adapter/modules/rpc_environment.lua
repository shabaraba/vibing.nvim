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

  -- How long `bin/hooks/pre-tool-use.sh` may block waiting for a decision. It travels here rather
  -- than in the generated hook settings because the script is one fixed file shared by every chat,
  -- and it is bound to the port on purpose: the script only ever waits when it has a port to wait
  -- on, so the two are meaningful together or not at all.
  require("vibing.infrastructure.hooks.wait_budget").bind(env)
end

return M
