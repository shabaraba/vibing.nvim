--- Adapter factory
--- Resolves an agent type ("claude" / "codex" / "copilot") to its adapter instance
--- @module vibing.infrastructure.adapter.factory

local M = {}

local Agents = require("vibing.core.constants.agents")

--- Resolve an agent type to its adapter module path
--- Unknown or nil agent types fall back to the claude adapter
--- @param agent_type string|nil
--- @return string
local function resolve_module(agent_type)
  return Agents.get(agent_type).adapter_module
end

--- Get the adapter instance name for an agent type.
--- Derived from the module path in agents.lua, so it cannot drift from what factory actually
--- loads.
--- @param agent_type string|nil
--- @return string
function M.adapter_name(agent_type)
  return resolve_module(agent_type):match("[^.]+$")
end

--- Get the agent type an adapter instance belongs to — the reverse of `adapter_name`.
--- Lets a caller holding the adapter that actually ran name its backend, instead of re-deriving
--- it from frontmatter that may have been edited since the request started.
--- @param adapter table|nil Adapter instance (its `name`, e.g. "claude_cli", is what is matched)
--- @return string agent_type Falls back to the default agent for an unrecognised adapter
function M.agent_id(adapter)
  local name = adapter and adapter.name
  for _, id in ipairs(Agents.ORDER) do
    if M.adapter_name(id) == name then
      return id
    end
  end
  return Agents.DEFAULT
end

--- Create an adapter instance for an agent type
--- @param agent_type string|nil
--- @param config Vibing.Config
--- @return Vibing.Adapter
function M.create(agent_type, config)
  return require(resolve_module(agent_type)):new(config)
end

return M
