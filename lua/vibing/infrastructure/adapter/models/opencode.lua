--- Which models the OpenCode CLI would accept, asked of the CLI.
--- @module vibing.infrastructure.adapter.models.opencode

local M = {}

function M.command(config)
  local path = vim.tbl_get(config or {}, "ai", "agents", "opencode", "path")
  if type(path) == "string" and path ~= "" then
    return { vim.fn.expand(path), "models" }
  end
  return { "opencode", "models" }
end

function M.parse(stdout)
  local candidates = {}
  for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    local value = vim.trim(line)
    if value ~= "" and value:match("^%S+/%S+$") then
      table.insert(candidates, { value = value, description = "Available in the OpenCode CLI" })
    end
  end
  return candidates
end

return M
