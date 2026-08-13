--- Grok CLI event processor for `grok --output-format streaming-json` output
--- Processes JSONL events from the Grok Build CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.grok_event_processor

local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

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

--- Handle a "thought" delta (Grok's reasoning stream)
--- Confirmed via real CLI: "thought" arrives as many small word-by-word deltas.
--- A "💭 " marker is emitted once when entering thought mode; a blank line closes it on "text".
--- @param msg table
--- @param context table
local function handle_thought(msg, context)
  if context.onFirstResponse then
    context.onFirstResponse()
  end
  if context._grok_mode ~= "thought" then
    context._grok_mode = "thought"
    emit_chunk("\n💭 ", context)
  end
  emit_chunk(msg.data or "", context)
end

--- Handle a "text" delta (Grok's response stream)
--- @param msg table
--- @param context table
local function handle_text(msg, context)
  if context.onFirstResponse then
    context.onFirstResponse()
  end
  if context._grok_mode == "thought" then
    emit_chunk("\n\n", context)
  end
  context._grok_mode = "text"
  emit_chunk(msg.data or "", context)
end

--- Handle the "end" event (turn completion — carries sessionId/usage, not text)
--- Grok's headless output has no dedicated session-start event; sessionId is only known
--- once the turn ends. Completion itself is process-exit driven.
--- @param msg table
--- @param context table
local function handle_end(msg, context)
  if msg.sessionId and context.sessionManager and context.handleId then
    SessionManagerModule.store(context.sessionManager, context.handleId, msg.sessionId)
  end
end

local event_handlers = {
  thought = function(msg, context)
    handle_thought(msg, context)
    return true
  end,
  text = function(msg, context)
    handle_text(msg, context)
    return true
  end,
  ["end"] = function(msg, context)
    handle_end(msg, context)
    return true
  end,
  error = function(msg, context)
    if msg.message then
      table.insert(context.errorOutput, msg.message)
    end
    return true
  end,
}

--- Process a single JSON line from the Grok CLI output
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
