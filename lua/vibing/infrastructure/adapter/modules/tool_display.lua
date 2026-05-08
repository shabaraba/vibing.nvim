--- Shared tool display helpers for event processors
--- Provides marker resolution, display mode, and result formatting
--- @module vibing.infrastructure.adapter.modules.tool_display

local M = {}

local DEFAULT_MARKER = "⏺"

--- Get tool markers config from vibing.config
--- @return table|nil
function M.get_markers_config()
  local ok, config_mod = pcall(require, "vibing.config")
  if ok then
    local config = config_mod.get()
    return config.ui and config.ui.tool_markers
  end
  return nil
end

--- Resolve tool marker from config
--- @param tool_name string
--- @param markers table|nil
--- @return string
function M.resolve_marker(tool_name, markers)
  if not markers then
    return DEFAULT_MARKER
  end
  local marker_config = markers[tool_name]
  if type(marker_config) == "string" then
    return marker_config
  end
  if type(marker_config) == "table" and marker_config.default then
    return marker_config.default
  end
  return markers.default or DEFAULT_MARKER
end

--- Get tool result display mode from vibing.config
--- @return string "none"|"compact"|"full"
function M.get_display_mode()
  local ok, config_mod = pcall(require, "vibing.config")
  if ok then
    local config = config_mod.get()
    return config.ui and config.ui.tool_result_display or "compact"
  end
  return "compact"
end

--- Format tool result text for display
--- @param result_text string
--- @param display_mode string
--- @return string
function M.format_result_text(result_text, display_mode)
  if display_mode == "none" or not result_text or result_text == "" then
    return ""
  end
  local display_text = result_text
  if display_mode == "compact" and #result_text > 100 then
    display_text = result_text:sub(1, 100) .. "..."
  end
  return "  ⎿  " .. display_text:gsub("\n", "\n     ") .. "\n"
end

return M
