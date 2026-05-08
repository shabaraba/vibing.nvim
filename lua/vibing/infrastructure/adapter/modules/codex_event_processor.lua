--- Codex CLI event processor for `codex exec --json` output
--- Processes JSONL events from the Codex CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.codex_event_processor

local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")

--- Handle "thread.started" event
--- @param msg table
--- @param context table
local function handle_thread_started(msg, context)
  if msg.thread_id and context.sessionManager and context.handleId then
    SessionManagerModule.store(context.sessionManager, context.handleId, msg.thread_id)
  end
  if context.onFirstResponse then
    context.onFirstResponse()
  end
end

--- Handle "item.completed" event
--- @param msg table
--- @param context table
local function handle_item_completed(msg, context)
  local item = msg.item
  if not item then
    return
  end

  if item.type == "agent_message" and item.text then
    table.insert(context.output, item.text)
    if context.onChunk then
      vim.schedule(function()
        context.onChunk(item.text)
      end)
    end
  end

  if item.type == "command_execution" and item.status == "completed" then
    if context._cached_markers == nil then
      context._cached_markers = ToolDisplay.get_markers_config() or false
    end
    local markers = context._cached_markers or nil
    local tool_name = item.tool_name or "Bash"
    local marker = ToolDisplay.resolve_marker(tool_name, markers)
    local cmd_display = item.command or ""
    local header = string.format("\n%s %s(%s)\n", marker, tool_name, cmd_display)

    if not context._cached_display_mode then
      context._cached_display_mode = ToolDisplay.get_display_mode()
    end
    local result_display = ToolDisplay.format_result_text(item.aggregated_output or "", context._cached_display_mode)
    local text = header .. result_display

    table.insert(context.output, text)
    if context.onChunk then
      vim.schedule(function()
        context.onChunk(text)
      end)
    end
  end
end

--- Handle "item.started" event
--- @param msg table
--- @param context table
local function handle_item_started(msg, context)
  local item = msg.item
  if not item then
    return
  end

  if item.type == "command_execution" and context.opts and context.opts.on_tool_use then
    local tool_name = item.tool_name or "Bash"
    local command = item.command or ""
    vim.schedule(function()
      context.opts.on_tool_use(tool_name, nil, command)
    end)
  end
end

--- Handle "turn.failed" event
--- @param msg table
--- @param context table
local function handle_turn_failed(msg, context)
  local err = msg.error
  if err then
    local message = type(err) == "table" and err.message or tostring(err)
    table.insert(context.errorOutput, message)
  end
end

--- Handle "error" event
--- @param msg table
--- @param context table
local function handle_error(msg, context)
  if msg.message then
    table.insert(context.errorOutput, msg.message)
  end
end

--- Event handler dispatch table
local event_handlers = {
  ["thread.started"] = function(msg, context)
    handle_thread_started(msg, context)
    return true
  end,
  ["turn.started"] = function(msg, context)
    if context.onFirstResponse then
      context.onFirstResponse()
    end
    return true
  end,
  ["item.completed"] = function(msg, context)
    handle_item_completed(msg, context)
    return true
  end,
  ["item.started"] = function(msg, context)
    handle_item_started(msg, context)
    return true
  end,
  ["turn.completed"] = function()
    return true
  end,
  ["turn.failed"] = function(msg, context)
    handle_turn_failed(msg, context)
    return true
  end,
  ["error"] = function(msg, context)
    handle_error(msg, context)
    return true
  end,
}

--- Process a single JSON line from the Codex CLI output
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
