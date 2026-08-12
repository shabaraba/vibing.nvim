--- Shared buffer-argument handling for RPC handlers.
--- @module vibing.infrastructure.rpc.handlers.bufnr

local M = {}

--- Turn an incoming bufnr argument into a real buffer number.
---
--- Errors rather than defaulting when the caller gave nothing: the tools that use this change what
--- the user sees, so guessing a buffer is worse than refusing.
--- @param bufnr any
--- @return number
function M.resolve(bufnr)
  if type(bufnr) ~= "number" then
    error("Missing bufnr parameter")
  end
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

return M
