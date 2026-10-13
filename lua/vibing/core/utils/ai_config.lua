--- Resolve agent/model/effort for a purpose without inheriting another agent's model.
local Agents = require("vibing.core.constants.agents")
local M = {}

---@param config table?
---@param agent_id string?
---@param helpers boolean?
---@return table selection
function M.resolve(config, agent_id, helpers)
  local ai = (config or {}).ai or {}
  local chat = ai.chat or {}
  local purpose = helpers and (ai.helpers or {}) or chat
  local configured_agent = purpose.agent or chat.agent or Agents.DEFAULT
  local id = agent_id or configured_agent
  local def = Agents.get(id)
  local matches = id == configured_agent
  local default_model
  if helpers then
    default_model = def.helper_model
  else
    default_model = def.chat_model
  end
  return {
    agent = def.id,
    model = matches and purpose.model or default_model,
    effort = (matches and purpose.effort) or (helpers and "low" or "default"),
  }
end

---@param config table?
---@param id string
---@return table
function M.agent_options(config, id)
  return vim.tbl_get(config or {}, "ai", "agents", id) or {}
end

return M
