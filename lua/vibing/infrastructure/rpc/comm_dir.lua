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

--- Path of the comm directory a given RPC port would use.
--- @param port number|string
--- @return string
function M.for_port(port)
  return M.ROOT .. "/" .. M.PREFIX .. tostring(port)
end

--- Path of the comm directory for this Neovim instance.
---
--- The key — the RPC port, or the pid when there is no port, so two portless instances cannot share
--- a directory — is `rpc/instance_key.lua`. It moved there when the generated hook settings needed
--- the same distinction for the same reason.
--- @return string
function M.path()
  local override = vim.env[M.ENV_VAR]
  if override and override ~= "" then
    return override
  end

  return M.for_port(require("vibing.infrastructure.rpc.instance_key").get())
end

return M
