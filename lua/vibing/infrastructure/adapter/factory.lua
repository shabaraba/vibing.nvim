--- Adapter factory
--- Resolves an agent type ("claude" / "codex" / "copilot") to its adapter instance
--- @module vibing.infrastructure.adapter.factory

local M = {}

local ADAPTER_MODULES = {
  claude = "vibing.infrastructure.adapter.claude_cli",
  codex = "vibing.infrastructure.adapter.codex_cli",
  copilot = "vibing.infrastructure.adapter.copilot_cli",
}

local ADAPTER_NAMES = {
  claude = "claude_cli",
  codex = "codex_cli",
  copilot = "copilot_cli",
}

local DEFAULT_AGENT = "claude"

--- Get the adapter instance name for an agent type
--- @param agent_type string|nil
--- @return string
function M.adapter_name(agent_type)
  return ADAPTER_NAMES[agent_type] or ADAPTER_NAMES[DEFAULT_AGENT]
end

--- Create an adapter instance for an agent type
--- Unknown or nil agent types fall back to the claude adapter
--- @param agent_type string|nil
--- @param config Vibing.Config
--- @return Vibing.Adapter
function M.create(agent_type, config)
  local module_path = ADAPTER_MODULES[agent_type] or ADAPTER_MODULES[DEFAULT_AGENT]
  return require(module_path):new(config)
end

return M
