--- CLI event processor for `claude -p --output-format stream-json` output
--- Processes JSON Lines from the Claude CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.cli_event_processor

local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

local DEFAULT_MARKER = "⏺"

--- Extract brief summary from tool input for display
--- @param tool_name string
--- @param tool_input table
--- @return string
local function extract_input_summary(tool_name, tool_input)
  if tool_name == "Task" or tool_name == "Agent" then
    if tool_input.subagent_type and tool_input.subagent_type ~= "" then
      return tool_input.subagent_type
    end
    if tool_input.prompt and tool_input.prompt ~= "" then
      local p = vim.trim(tool_input.prompt)
      return #p > 30 and p:sub(1, 30) .. "..." or p
    end
    return "default"
  end

  return tool_input.command
    or tool_input.file_path
    or tool_input.pattern
    or tool_input.query
    or tool_input.url
    or ""
end

--- Resolve tool marker from config
--- @param tool_name string
--- @param markers table|nil
--- @return string
local function resolve_marker(tool_name, markers)
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

--- Get tool markers config
--- @return table|nil
local function get_markers_config()
  local ok, config_mod = pcall(require, "vibing.config")
  if ok then
    local config = config_mod.get()
    return config.ui and config.ui.tool_markers
  end
  return nil
end

--- Get tool result display mode
--- @return string
local function get_display_mode()
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
local function format_result_text(result_text, display_mode)
  if display_mode == "none" or not result_text or result_text == "" then
    return ""
  end

  local display_text = result_text
  if display_mode == "compact" and #result_text > 100 then
    display_text = result_text:sub(1, 100) .. "..."
  end

  return "  ⎿  " .. display_text:gsub("\n", "\n     ") .. "\n"
end

--- Format and emit a tool_result block as a chunk
--- @param block table tool_result content block
--- @param tool_map table tool_use_id → {name, input} map
--- @param context table event processing context
local function emit_tool_result(block, tool_map, context)
  local tool_info = tool_map[block.tool_use_id]
  if not tool_info then
    return
  end

  local tool_name = tool_info.name
  local tool_input = tool_info.input or {}
  local input_summary = extract_input_summary(tool_name, tool_input)
  local markers = get_markers_config()
  local marker = resolve_marker(tool_name, markers)
  local header = string.format("\n%s %s(%s)\n", marker, tool_name, input_summary)

  local result_text = ""
  if type(block.content) == "string" then
    result_text = block.content
  elseif type(block.content) == "table" then
    local parts = {}
    for _, c in ipairs(block.content) do
      if c.text then
        table.insert(parts, c.text)
      end
    end
    result_text = table.concat(parts, "")
  end

  local display_mode = get_display_mode()
  local result_display = format_result_text(result_text, display_mode)
  local text = header .. result_display

  if context.onChunk then
    table.insert(context.output, text)
    vim.schedule(function()
      context.onChunk(text)
    end)
  end

  tool_map[block.tool_use_id] = nil
end

--- Store session_id if present
--- @param msg table
--- @param context table
local function store_session(msg, context)
  if msg.session_id and context.sessionManager and context.handleId then
    SessionManagerModule.store(context.sessionManager, context.handleId, msg.session_id)
  end
end

--- Handle "system" event (init, hook events)
local function handle_system_event(msg, context)
  store_session(msg, context)
  -- Cancel timeout on first system event (proves CLI is alive)
  if context.onFirstResponse then
    context.onFirstResponse()
  end
end

--- Handle "stream_event" (partial streaming)
local function handle_stream_event(msg, context)
  local event = msg.event
  if not event then
    return
  end

  if event.type == "content_block_start" and event.content_block then
    local block = event.content_block
    if block.type == "tool_use" and block.name then
      context._tool_use_map = context._tool_use_map or {}
      context._tool_use_map[block.id] = {
        name = block.name,
        input = block.input or {},
        input_json = "",
      }
      context._current_tool_id = block.id
      context._emitted_tool_ids = context._emitted_tool_ids or {}
      context._emitted_tool_ids[block.id] = true

      -- Notify on_tool_use callback
      if context.opts and context.opts.on_tool_use then
        local input = block.input or {}
        vim.schedule(function()
          context.opts.on_tool_use(block.name, input.file_path, input.command)
        end)
      end
    end
  end

  if event.type == "content_block_delta" and event.delta then
    local delta = event.delta

    if delta.type == "text_delta" and delta.text and context.onChunk then
      table.insert(context.output, delta.text)
      vim.schedule(function()
        context.onChunk(delta.text)
      end)
    end

    if delta.type == "input_json_delta" and delta.partial_json then
      local tool_map = context._tool_use_map or {}
      if context._current_tool_id and tool_map[context._current_tool_id] then
        local info = tool_map[context._current_tool_id]
        if info.input_json ~= nil then
          info.input_json = info.input_json .. delta.partial_json
        end
      end
    end
  end

  store_session(msg, context)
end

--- Handle "assistant" event (complete response message)
local function handle_assistant_event(msg, context)
  local message = msg.message
  if not message then
    return
  end

  store_session(msg, context)

  local tool_map = context._tool_use_map or {}
  local emitted = context._emitted_tool_ids or {}

  for _, block in ipairs(message.content or {}) do
    -- Update tool_use_map with complete input from assistant message
    if block.type == "tool_use" and block.id then
      if tool_map[block.id] then
        tool_map[block.id].input = block.input or tool_map[block.id].input
        tool_map[block.id].name = block.name or tool_map[block.id].name
      else
        tool_map[block.id] = {
          name = block.name,
          input = block.input or {},
        }
      end

      -- Emit on_tool_use for tools not seen via stream_event
      if not emitted[block.id] and context.opts and context.opts.on_tool_use then
        local input = block.input or {}
        vim.schedule(function()
          context.opts.on_tool_use(block.name, input.file_path, input.command)
        end)
      end
    end

    if block.type == "tool_result" and block.tool_use_id then
      emit_tool_result(block, tool_map, context)
    end
  end

  context._tool_use_map = tool_map
end

--- Handle "user" event (tool results in multi-turn)
local function handle_user_event(msg, context)
  local message = msg.message
  if not message then
    return
  end

  store_session(msg, context)

  local tool_map = context._tool_use_map or {}

  for _, block in ipairs(message.content or {}) do
    if block.type == "tool_result" and block.tool_use_id then
      emit_tool_result(block, tool_map, context)
    end
  end

  context._tool_use_map = tool_map
end

--- Handle "result" event (completion)
local function handle_result_event(msg, context)
  store_session(msg, context)

  if msg.subtype == "error" or msg.is_error then
    table.insert(context.errorOutput, msg.result or "Unknown error")
  end
end

--- Event handler dispatch table
local event_handlers = {
  system = function(msg, context)
    handle_system_event(msg, context)
    return true
  end,
  stream_event = function(msg, context)
    handle_stream_event(msg, context)
    return true
  end,
  assistant = function(msg, context)
    handle_assistant_event(msg, context)
    return true
  end,
  user = function(msg, context)
    handle_user_event(msg, context)
    return true
  end,
  result = function(msg, context)
    handle_result_event(msg, context)
    return true
  end,
  rate_limit_event = function()
    return true
  end,
}

--- Process a single JSON line from the CLI output
--- @param line string JSON string
--- @param context table Processing context
--- @return boolean success Whether the line was processed
function M.processLine(line, context)
  if line == "" or not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok or not msg or not msg.type then
    return false
  end

  local handler = event_handlers[msg.type]
  if handler then
    return handler(msg, context)
  end

  return true
end

return M
