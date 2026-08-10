--- Display helpers for copilot tool execution events
--- Formats tool.execution_start / tool.execution_complete payloads
--- @module vibing.infrastructure.adapter.modules.copilot_item_display

local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")

local M = {}

local ARGUMENT_SUMMARY_LIMIT = 100

--- copilot tool names that map onto a vibing-style display label.
--- Names absent here are displayed verbatim; extend as more are confirmed on real runs.
local TOOL_LABELS = {
  bash = "Bash",
  view = "Read",
  create = "Write",
  edit = "Edit",
  web_search = "WebSearch",
}

--- Map a copilot tool name to its display label
--- @param tool_name string
--- @return string
function M.resolve_label(tool_name)
  return TOOL_LABELS[tool_name] or tool_name
end

--- Summarize tool arguments for the header
--- @param args table|nil
--- @return string summary
--- @return string kind "command"|"path"|"other"
function M.summarize_arguments(args)
  if type(args) ~= "table" then
    return "", "other"
  end
  if type(args.command) == "string" then
    return args.command, "command"
  end
  if type(args.path) == "string" then
    return args.path, "path"
  end
  if type(args.file_path) == "string" then
    return args.file_path, "path"
  end
  if type(args.query) == "string" then
    return args.query, "other"
  end

  local ok, encoded = pcall(vim.json.encode, args)
  if not ok then
    return "", "other"
  end
  if #encoded > ARGUMENT_SUMMARY_LIMIT then
    return encoded:sub(1, ARGUMENT_SUMMARY_LIMIT) .. "...", "other"
  end
  return encoded, "other"
end

--- Turn a payload value into displayable text, preferring one well-known key when it is a table.
--- copilot sends `error` as a table ({ message, code }) and `result` as ({ content, ... }), so
--- both are unwrapped rather than stringified — tostring() leaks a table's address into the chat.
--- @param value any
--- @param preferred_key string
--- @return string
local function to_text(value, preferred_key)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value[preferred_key]) == "string" then
      return value[preferred_key]
    end
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or ""
  end
  if value == nil then
    return ""
  end
  return tostring(value)
end

--- Turn an error-ish value into displayable text
--- @param value any
--- @return string
function M.stringify_message(value)
  return to_text(value, "message")
end

--- Extract displayable text from a tool.execution_complete payload
--- @param data table
--- @return string
function M.extract_result_text(data)
  if data.result ~= nil then
    return to_text(data.result, "content")
  end
  return to_text(data.error, "message")
end

--- Format the header emitted when a tool starts executing
--- @param data table tool.execution_start payload
--- @param context table
--- @return string
function M.format_execution_start(data, context)
  local markers = ToolDisplay.get_cached_markers(context)
  local label = M.resolve_label(data.toolName or "tool")
  local marker = ToolDisplay.resolve_marker(label, markers)
  local summary = M.summarize_arguments(data.arguments)
  return string.format("\n%s %s(%s)\n", marker, label, summary)
end

--- Format the result emitted when a tool finishes executing
--- @param data table tool.execution_complete payload
--- @param context table
--- @return string
function M.format_execution_complete(data, context)
  local display_mode = ToolDisplay.get_cached_display_mode(context)
  -- Extracting can JSON-encode a large result payload, so skip it when nothing is displayed.
  if display_mode == "none" then
    return ""
  end

  local text = M.extract_result_text(data)
  if text ~= "" and data.success == false then
    text = "Error: " .. text
  end
  return ToolDisplay.format_result_text(text, display_mode)
end

return M
