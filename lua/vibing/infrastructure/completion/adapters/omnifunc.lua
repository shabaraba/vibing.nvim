---@class Vibing.OmnifuncAdapter
---Fallback omnifunc adapter for vibing completion (when nvim-cmp is not available)
---Uses synchronous methods to avoid event loop blocking issues
---@module "vibing.infrastructure.completion.adapters.omnifunc"
local M = {}

local slash_source = require("vibing.application.completion.sources.slash")
local file_source = require("vibing.application.completion.sources.file")
local agent_source = require("vibing.application.completion.sources.agent")

---@type {context: Vibing.TriggerContext, source: "slash"|"file"|"agent"}?
local _last_match = nil

---Sources to check in order of priority
local sources = {
  { module = slash_source, name = "slash" },
  { module = file_source, name = "file" },
  { module = agent_source, name = "agent" },
}

---Get candidates for a source
---@param source_name "slash"|"file"|"agent"
---@param context Vibing.TriggerContext
---@return Vibing.CompletionItem[]
local function get_items(source_name, context)
  if source_name == "file" then
    return file_source.get_candidates_sync(context)
  elseif source_name == "agent" then
    return agent_source.get_candidates_sync(context)
  end
  local items = {}
  slash_source.get_candidates(context, function(result)
    items = result
  end)
  return items
end

---Omnifunc implementation
---@param findstart 0|1
---@param base string
---@return number|table
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]

    for _, src in ipairs(sources) do
      local ctx = src.module.get_trigger_context(line, col)
      if ctx then
        _last_match = { context = ctx, source = src.name }
        return ctx.start_col - 1
      end
    end

    _last_match = nil
    return -1
  end

  if not _last_match then
    return {}
  end

  local items = get_items(_last_match.source, _last_match.context)
  local results = {}
  local base_lower = base:lower()
  local base_pattern = "^" .. vim.pesc(base_lower)

  for _, item in ipairs(items) do
    if base == "" or item.word:lower():find(base_pattern) then
      table.insert(results, {
        word = item.word,
        abbr = item.label,
        kind = M._kind_to_abbr(item.kind),
        menu = item.description or "",
      })
    end
  end

  return results
end

---Convert kind to abbreviation for omnifunc display
---@param kind string
---@return string
function M._kind_to_abbr(kind)
  local abbrs = {
    Command = "[Cmd]",
    Skill = "[Skill]",
    File = "[File]",
    Agent = "[Agent]",
    Argument = "[Arg]",
  }
  return abbrs[kind] or "[?]"
end

return M
