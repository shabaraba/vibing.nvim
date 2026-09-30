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

--- The chat line a background subagent's completion is worth.
---
--- Deliberately metadata only. The subagent's own answer reaches the model through the
--- notification and it will say what it found in its own words; repeating the whole thing here
--- would print every report twice.
--- @param event table a `background_task_done` canonical event
--- @param entry Vibing.BackgroundTask? what the launch recorded, when the launch was seen
--- @param context table
--- @return string
function M.format_completion(event, entry, context)
  local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")
  local parts = {}
  if event.status and event.status ~= "completed" then
    table.insert(parts, event.status)
  end
  local usage = type(event.usage) == "table" and event.usage or {}
  if type(usage.duration_ms) == "number" then
    local When = require("vibing.core.utils.when")
    table.insert(parts, When.format_duration(math.floor(usage.duration_ms / 1000 + 0.5)))
  end
  if type(usage.total_tokens) == "number" then
    local TokenUsage = require("vibing.core.utils.token_usage")
    table.insert(parts, TokenUsage.humanize(usage.total_tokens) .. " tokens")
  end

  return string.format(
    "\n%s Subagent finished: %s%s\n",
    ToolDisplay.resolve_marker("Agent", ToolDisplay.get_cached_markers(context)),
    (entry and entry.description) or event.task_id or "subagent",
    #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
  )
end

return M
