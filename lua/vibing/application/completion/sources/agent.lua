---@class Vibing.AgentSource
---Completion source for @agent: references
---@module "vibing.application.completion.sources.agent"
local M = {}

M.name = "agent"

local agents_provider = require("vibing.infrastructure.completion.providers.agents")

---Detect trigger context for agent names
---@param line string Current line content
---@param col number Cursor column (0-indexed)
---@return Vibing.TriggerContext?
function M.get_trigger_context(line, col)
  local before_cursor = line:sub(1, col)

  -- Pattern: "@agent:" followed by optional agent name
  local agent_match = before_cursor:match("@agent:([^%s]*)$")
  if agent_match ~= nil then
    local trigger_pos = before_cursor:find("@agent:")
    return {
      trigger = "agent",
      query = agent_match,
      start_col = trigger_pos + 7, -- After "@agent:"
    }
  end

  return nil
end

---Filter items by query (substring match)
---@param items Vibing.CompletionItem[]
---@param query string?
---@return Vibing.CompletionItem[]
local function filter_items(items, query)
  if not query or query == "" then
    return items
  end
  local query_lower = query:lower()
  return vim.tbl_filter(function(item)
    return item.filterText:lower():find(query_lower, 1, true) ~= nil
  end, items)
end

---Get completion candidates (sync - no async needed for cached data)
---@param context Vibing.TriggerContext
---@param callback fun(items: Vibing.CompletionItem[])
function M.get_candidates(context, callback)
  local items = agents_provider.get_all()
  callback(filter_items(items, context.query))
end

---Get completion candidates synchronously (for omnifunc)
---@param context Vibing.TriggerContext
---@return Vibing.CompletionItem[]
function M.get_candidates_sync(context)
  return filter_items(agents_provider.get_all(), context.query)
end

return M
