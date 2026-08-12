--- Resolves the directory the hook scripts and Neovim exchange request/response files through.
---
--- Single source of truth for what used to be a `/tmp/vibing-hook-<port>` string literal repeated
--- in permission.lua, rate_limit.lua and hook_cleanup.lua. `bin/hooks/*.sh` read the same
--- `$VIBING_HOOK_COMM_DIR` override, and the adapters spawn the CLI with `vim.fn.environ()`, so
--- both sides always agree.
---
--- @module vibing.infrastructure.rpc.comm_dir

local M = {}

M.ENV_VAR = "VIBING_HOOK_COMM_DIR"

--- Base directory containing every per-port comm directory.
M.ROOT = "/tmp"

--- Prefix of a comm directory's basename.
M.PREFIX = "vibing-hook-"

--- Current RPC port, or nil when the server is not listening.
--- @return number?
local function current_port()
  local ok, rpc_server = pcall(require, "vibing.infrastructure.rpc.server")
  if not ok then
    return nil
  end
  local port = rpc_server.get_port()
  if not port or port == 0 then
    return nil
  end
  return port
end

--- Path of the comm directory a given RPC port would use.
--- @param port number|string
--- @return string
function M.for_port(port)
  return M.ROOT .. "/" .. M.PREFIX .. tostring(port)
end

--- Path of the comm directory for this Neovim instance.
--- @return string
function M.path()
  local override = vim.env[M.ENV_VAR]
  if override and override ~= "" then
    return override
  end

  local port = current_port()
  if port then
    return M.for_port(port)
  end

  -- No port to key on: stay per-process so two portless instances cannot share a directory.
  return M.for_port("0-" .. vim.fn.getpid())
end

return M
