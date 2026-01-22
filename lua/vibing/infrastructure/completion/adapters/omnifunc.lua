---@class Vibing.OmnifuncAdapter
---Fallback omnifunc adapter for vibing completion (when nvim-cmp is not available)
---Uses synchronous methods to avoid event loop blocking issues
---@module "vibing.infrastructure.completion.adapters.omnifunc"
local M = {}

local slash_source = require("vibing.application.completion.sources.slash")
local file_source = require("vibing.application.completion.sources.file")

---@type Vibing.TriggerContext?
local _last_context = nil
local _last_source = nil

---Omnifunc implementation
---@param findstart 0|1
---@param base string
---@return number|table
function M.complete(findstart, base)
  if findstart == 1 then
    -- Phase 1: Find start position
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]

    -- Check slash source first
    local slash_ctx = slash_source.get_trigger_context(line, col)
    if slash_ctx then
      _last_context = slash_ctx
      _last_source = "slash"
      return slash_ctx.start_col - 1 -- Convert to 0-indexed
    end

    -- Check file source
    local file_ctx = file_source.get_trigger_context(line, col)
    if file_ctx then
      _last_context = file_ctx
      _last_source = "file"
      return file_ctx.start_col - 1
    end

    _last_context = nil
    _last_source = nil
    return -1 -- No completion
  else
    -- Phase 2: Return candidates (synchronous)
    if not _last_context then
      return {}
    end

    local items = {}

    if _last_source == "slash" then
      -- Slash source is synchronous - use callback pattern for compatibility
      slash_source.get_candidates(_last_context, function(result)
        items = result
      end)
    elseif _last_source == "file" then
      -- File source has sync method
      items = file_source.get_candidates_sync(_last_context)
    end

    -- Filter by base and convert to omnifunc format
    local results = {}
    for _, item in ipairs(items) do
      if base == "" or item.word:lower():find("^" .. vim.pesc(base:lower())) then
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
end

---Convert kind to abbreviation for omnifunc display
---@param kind string
---@return string
function M._kind_to_abbr(kind)
  local abbrs = {
    Command = "[Cmd]",
    Skill = "[Skill]",
    File = "[File]",
    Argument = "[Arg]",
  }
  return abbrs[kind] or "[?]"
end

return M
