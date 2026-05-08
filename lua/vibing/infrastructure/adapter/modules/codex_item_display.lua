--- Display helpers for codex item types
--- Formats file_change, mcp_tool_call, reasoning, web_search items
--- @module vibing.infrastructure.adapter.modules.codex_item_display

local M = {}

local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")

local CHANGE_KIND_LABELS = {
  add = "created",
  delete = "deleted",
  update = "modified",
}

--- Extract inner command from codex shell wrapper
--- @param cmd string
--- @return string
function M.extract_inner_command(cmd)
  local inner = cmd:match("^/[^ ]+ %-lc [\"'](.+)[\"']$")
  return inner or cmd
end

--- Format a command_execution item
--- @param item table
--- @param context table
--- @return string
function M.format_command_execution(item, context)
  local markers = M._get_markers(context)
  local tool_name = item.tool_name or "Bash"
  local marker = ToolDisplay.resolve_marker(tool_name, markers)
  local cmd_display = M.extract_inner_command(item.command or "")
  local header = string.format("\n%s %s(%s)\n", marker, tool_name, cmd_display)

  local display_mode = M._get_display_mode(context)
  local result = ToolDisplay.format_result_text(item.aggregated_output or "", display_mode)
  return header .. result
end

--- Format a file_change item
--- @param item table
--- @return string
function M.format_file_change(item, context)
  local markers = M._get_markers(context)
  local marker = ToolDisplay.resolve_marker("Edit", markers)
  local changes = item.changes or {}

  if #changes == 0 then
    return ""
  end

  local lines = {}
  for _, change in ipairs(changes) do
    local kind_label = CHANGE_KIND_LABELS[change.kind] or change.kind or "changed"
    table.insert(lines, string.format("  %s %s", kind_label, change.path or "unknown"))
  end

  local header = string.format("\n%s FileChange(%d files)\n", marker, #changes)
  return header .. table.concat(lines, "\n") .. "\n"
end

--- Format an mcp_tool_call item
--- @param item table
--- @return string
function M.format_mcp_tool_call(item, context)
  local markers = M._get_markers(context)
  local tool_label = item.tool or "unknown"
  if item.server then
    tool_label = item.server .. ":" .. tool_label
  end
  local marker = ToolDisplay.resolve_marker("mcp", markers)
  local header = string.format("\n%s MCP(%s)\n", marker, tool_label)

  local display_mode = M._get_display_mode(context)
  local result_text = ""
  if item.error then
    result_text = "Error: " .. tostring(item.error)
  elseif item.result then
    if type(item.result) == "table" and item.result.content then
      local parts = {}
      for _, c in ipairs(item.result.content) do
        if type(c) == "table" and c.text then
          table.insert(parts, c.text)
        elseif type(c) == "string" then
          table.insert(parts, c)
        end
      end
      result_text = table.concat(parts, "")
    else
      result_text = tostring(item.result)
    end
  end
  return header .. ToolDisplay.format_result_text(result_text, display_mode)
end

--- Format a reasoning item
--- @param item table
--- @return string
function M.format_reasoning(item)
  if not item.text or item.text == "" then
    return ""
  end
  return string.format("\n💭 %s\n", item.text)
end

--- Format a web_search item
--- @param item table
--- @return string
function M.format_web_search(item, context)
  local markers = M._get_markers(context)
  local marker = ToolDisplay.resolve_marker("WebSearch", markers)
  return string.format("\n%s WebSearch(%s)\n", marker, item.query or "")
end

--- @param context table
--- @return table|nil
function M._get_markers(context)
  if context._cached_markers == nil then
    context._cached_markers = ToolDisplay.get_markers_config() or false
  end
  return context._cached_markers or nil
end

--- @param context table
--- @return string
function M._get_display_mode(context)
  if not context._cached_display_mode then
    context._cached_display_mode = ToolDisplay.get_display_mode()
  end
  return context._cached_display_mode
end

return M
