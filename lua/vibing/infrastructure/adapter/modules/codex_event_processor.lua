--- Codex CLI event processor for `codex exec --json` output
--- Processes JSONL events from the Codex CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.codex_event_processor

local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ItemDisplay = require("vibing.infrastructure.adapter.modules.codex_item_display")

--- Emit formatted text to output and onChunk callback
--- @param text string
--- @param context table
local function emit_chunk(text, context)
  if text == "" then
    return
  end
  table.insert(context.output, text)
  if context.onChunk then
    vim.schedule(function()
      context.onChunk(text)
    end)
  end
end

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

--- Item type formatters for item.completed
local item_completed_handlers = {
  agent_message = function(item, context)
    if item.text then
      emit_chunk(item.text, context)
    end
  end,
  command_execution = function(item, context)
    emit_chunk(ItemDisplay.format_command_execution(item, context), context)
  end,
  file_change = function(item, context)
    emit_chunk(ItemDisplay.format_file_change(item, context), context)
  end,
  mcp_tool_call = function(item, context)
    emit_chunk(ItemDisplay.format_mcp_tool_call(item, context), context)
  end,
  reasoning = function(item, context)
    emit_chunk(ItemDisplay.format_reasoning(item), context)
  end,
  web_search = function(item, context)
    emit_chunk(ItemDisplay.format_web_search(item, context), context)
  end,
}

--- Handle "item.completed" event
--- @param msg table
--- @param context table
local function handle_item_completed(msg, context)
  local item = msg.item
  if not item then
    return
  end
  local handler = item_completed_handlers[item.type]
  if handler then
    handler(item, context)
  end
end

--- Notify on_tool_use for item.started
--- @param msg table
--- @param context table
local function handle_item_started(msg, context)
  local item = msg.item
  if not item or not context.opts or not context.opts.on_tool_use then
    return
  end

  if item.type == "command_execution" then
    local command = ItemDisplay.extract_inner_command(item.command or "")
    vim.schedule(function()
      context.opts.on_tool_use(item.tool_name or "Bash", nil, command)
    end)
  elseif item.type == "file_change" then
    local paths = {}
    for _, change in ipairs(item.changes or {}) do
      if change.path then
        table.insert(paths, change.path)
      end
    end
    vim.schedule(function()
      context.opts.on_tool_use("FileChange", table.concat(paths, ", "), nil)
    end)
  elseif item.type == "mcp_tool_call" then
    local label = (item.server or "") .. ":" .. (item.tool or "")
    vim.schedule(function()
      context.opts.on_tool_use("MCP", nil, label)
    end)
  end
end

--- Event handler dispatch table
local event_handlers = {
  ["thread.started"] = function(msg, context)
    handle_thread_started(msg, context)
    return true
  end,
  ["turn.started"] = function(_, context)
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
    local err = msg.error
    if err then
      table.insert(context.errorOutput, type(err) == "table" and err.message or tostring(err))
    end
    return true
  end,
  ["error"] = function(msg, context)
    if msg.message then
      table.insert(context.errorOutput, msg.message)
    end
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
