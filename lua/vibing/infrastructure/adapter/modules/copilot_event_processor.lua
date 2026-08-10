--- Copilot CLI event processor for `copilot --output-format json` output
--- Processes JSONL events from the Copilot CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.copilot_event_processor

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ItemDisplay = require("vibing.infrastructure.adapter.modules.copilot_item_display")

local M = {}

--- Emit formatted text to output and the onChunk callback
--- @param text string|nil
--- @param context table
local function emit_chunk(text, context)
  if not text or text == "" then
    return
  end
  table.insert(context.output, text)
  if context.onChunk then
    vim.schedule(function()
      context.onChunk(text)
    end)
  end
end

--- Notify opts.on_tool_use for a starting tool call
--- @param data table
--- @param context table
local function notify_tool_use(data, context)
  if not context.opts or not context.opts.on_tool_use then
    return
  end

  local label = ItemDisplay.resolve_label(data.toolName or "tool")
  local summary, kind = ItemDisplay.summarize_arguments(data.arguments)
  local file_path = kind == "path" and summary or nil
  local command = kind ~= "path" and summary or nil

  vim.schedule(function()
    context.opts.on_tool_use(label, file_path, command)
  end)
end

--- Event handler dispatch table
local event_handlers = {
  ["assistant.turn_start"] = function(_, context)
    if context.onFirstResponse then
      context.onFirstResponse()
    end
    return true
  end,

  ["assistant.message_delta"] = function(msg, context)
    local data = msg.data or {}
    if data.messageId then
      context._streamed_messages = context._streamed_messages or {}
      context._streamed_messages[data.messageId] = true
    end
    emit_chunk(data.deltaContent, context)
    return true
  end,

  -- Fallback for runs where streaming deltas never arrive (e.g. `--stream off`
  -- forced by user config): emit the whole message only if nothing was streamed.
  ["assistant.message"] = function(msg, context)
    local data = msg.data or {}
    local streamed = context._streamed_messages
      and data.messageId
      and context._streamed_messages[data.messageId]
    if not streamed then
      emit_chunk(data.content, context)
    end
    return true
  end,

  ["tool.execution_start"] = function(msg, context)
    local data = msg.data or {}
    emit_chunk(ItemDisplay.format_execution_start(data, context), context)
    notify_tool_use(data, context)
    return true
  end,

  ["tool.execution_complete"] = function(msg, context)
    emit_chunk(ItemDisplay.format_execution_complete(msg.data or {}, context), context)
    return true
  end,

  ["result"] = function(msg, context)
    if msg.sessionId and context.sessionManager and context.handleId then
      SessionManagerModule.store(context.sessionManager, context.handleId, msg.sessionId)
    end
    return true
  end,

  ["error"] = function(msg, context)
    local message = msg.message or (msg.data and msg.data.message)
    if message ~= nil then
      -- Unwrap the same way tool errors are unwrapped; a table message would otherwise
      -- surface as "table: 0x..." in the chat buffer.
      local text = ItemDisplay.stringify_message(message)
      if text ~= "" then
        table.insert(context.errorOutput, text)
      end
    end
    return true
  end,
}

--- Process a single JSON line from the Copilot CLI output
--- @param line string JSON string
--- @param context table Processing context
--- @return boolean success Whether the line was processed
function M.processLine(line, context)
  if line == "" or not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" or not msg.type then
    return false
  end

  local handler = event_handlers[msg.type]
  if handler then
    return handler(msg, context)
  end

  return true
end

return M
