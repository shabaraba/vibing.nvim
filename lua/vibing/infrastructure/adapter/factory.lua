--- Adapter factory: constructs the right CLI adapter instance for an agent type
--- @module vibing.infrastructure.adapter.factory

local M = {}

--- @type table<string, string>
local ADAPTER_MODULE_BY_AGENT = {
  claude = "vibing.infrastructure.adapter.claude_cli",
  codex = "vibing.infrastructure.adapter.codex_cli",
  grok = "vibing.infrastructure.adapter.grok_cli",
}

--- Resolve the module path for an agent type, falling back to claude for nil/unknown values
--- @param agent_type string|nil "claude"|"codex"|"grok"
--- @return string module_path
local function resolve_module_path(agent_type)
  return ADAPTER_MODULE_BY_AGENT[agent_type] or ADAPTER_MODULE_BY_AGENT.claude
end

--- Construct a new adapter instance for the given agent type
--- @param agent_type string|nil "claude"|"codex"|"grok" (defaults to claude for nil/unknown)
--- @param config Vibing.Config
--- @return table adapter
function M.create(agent_type, config)
  local Adapter = require(resolve_module_path(agent_type))
  return Adapter:new(config)
end

--- The `adapter.name` value that M.create(agent_type, ...) would produce, without constructing
--- an instance — used to check whether an already-constructed adapter already matches.
--- @param agent_type string|nil
--- @return string adapter_name
function M.adapter_name_for(agent_type)
  return resolve_module_path(agent_type):match("%.([%w_]+)$")
end

return M
