--- Adapter factory
--- Resolves an agent type ("claude" / "codex" / "copilot") to its adapter instance
--- @module vibing.infrastructure.adapter.factory

local M = {}

local ADAPTER_MODULES = {
  claude = "vibing.infrastructure.adapter.claude_cli",
  codex = "vibing.infrastructure.adapter.codex_cli",
  copilot = "vibing.infrastructure.adapter.copilot_cli",
}

local DEFAULT_AGENT = "claude"

--- Resolve an agent type to its adapter module path
--- Unknown or nil agent types fall back to the claude adapter
--- @param agent_type string|nil
--- @return string
local function resolve_module(agent_type)
  return ADAPTER_MODULES[agent_type] or ADAPTER_MODULES[DEFAULT_AGENT]
end

--- Get the adapter instance name for an agent type.
--- Derived from the module path so it cannot drift from ADAPTER_MODULES.
--- @param agent_type string|nil
--- @return string
function M.adapter_name(agent_type)
  return resolve_module(agent_type):match("[^.]+$")
end

--- Create an adapter instance for an agent type
--- @param agent_type string|nil
--- @param config Vibing.Config
--- @return Vibing.Adapter
function M.create(agent_type, config)
  return require(resolve_module(agent_type)):new(config)
end

return M
