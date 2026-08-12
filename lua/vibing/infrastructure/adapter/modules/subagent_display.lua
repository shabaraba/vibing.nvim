--- Formatting for subagent output, so a subagent's reasoning reads as its own voice rather than
--- as part of the parent's answer.
--- @module vibing.infrastructure.adapter.modules.subagent_display

local M = {}

--- Left rail on every subagent line, matching the marker style tool results already use.
local RAIL = "  │ "

--- Whether each forwarded line carries a `[<subagent_type>]` label
--- @return boolean
function M.get_show_prefix()
  local ok, config_mod = pcall(require, "vibing.config")
  if not ok then
    return false
  end
  local config = config_mod.get()
  local subagent = config.agent and config.agent.subagent
  return (subagent and subagent.show_prefix) == true
end

--- Get show_prefix, cached on the per-stream processing context the way tool_display caches its
--- markers: config cannot change mid-turn and this is consulted once per tool result.
--- @param context table
--- @return boolean
function M.get_cached_show_prefix(context)
  if context._cached_show_prefix == nil then
    context._cached_show_prefix = M.get_show_prefix()
  end
  return context._cached_show_prefix
end

--- Render buffered subagent text as an indented block.
--- @param subagent_type string|nil
--- @param text string
--- @param show_prefix boolean
--- @return string formatted Empty string when there is nothing to show
function M.format_buffer(subagent_type, text, show_prefix)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return ""
  end

  local prefix = RAIL
  if show_prefix then
    local label = type(subagent_type) == "string" and subagent_type ~= "" and subagent_type or "subagent"
    prefix = string.format("%s[%s] ", RAIL, label)
  end

  local lines = {}
  for _, line in ipairs(vim.split(vim.trim(text), "\n", { plain = true })) do
    table.insert(lines, prefix .. line)
  end

  return table.concat(lines, "\n") .. "\n"
end

return M
