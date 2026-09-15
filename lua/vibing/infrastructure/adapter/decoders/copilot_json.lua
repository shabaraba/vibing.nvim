--- `copilot -p --output-format json --stream on`, as canonical events.
---
--- Shapes captured from copilot 1.0.78. Tool calls arrive as `tool.execution_start` with the
--- arguments and `tool.execution_complete` with the result, paired by `toolCallId`.
--- @module vibing.infrastructure.adapter.decoders.copilot_json

local M = {}

--- Turn a payload value into displayable text, preferring one well-known key when it is a table.
--- copilot sends `error` as a table ({ message, code }) and `result` as ({ content, ... }), so
--- both are unwrapped rather than stringified -- tostring() leaks a table's address into the chat.
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

--- @param args any `arguments` as sent: a table, or a JSON string in some payloads
--- @return table
local function arguments_table(args)
  if type(args) == "string" then
    local ok, decoded = pcall(vim.json.decode, args)
    return ok and type(decoded) == "table" and decoded or {}
  end
  return type(args) == "table" and args or {}
end

--- A tool call id, synthesised when copilot sent none so start and end still pair up.
--- @param data table
--- @param state table
--- @return string
local function call_id(data, state)
  if data.toolCallId then
    return tostring(data.toolCallId)
  end
  state.anonymous_calls = (state.anonymous_calls or 0) + 1
  state.last_anonymous_id = "copilot-call-" .. state.anonymous_calls
  return state.last_anonymous_id
end

local by_type = {}

by_type["assistant.turn_start"] = function(_, events)
  table.insert(events, { kind = "first_response" })
end

by_type["assistant.message_delta"] = function(msg, events, state)
  local data = msg.data or {}
  if data.messageId then
    state.streamed = state.streamed or {}
    state.streamed[data.messageId] = true
  end
  if data.deltaContent and data.deltaContent ~= "" then
    table.insert(events, { kind = "text", delta = data.deltaContent })
  end
end

--- Fallback for runs where streaming deltas never arrive (e.g. `--stream off` forced by user
--- config): emit the whole message only if nothing was streamed for it.
by_type["assistant.message"] = function(msg, events, state)
  local data = msg.data or {}
  local streamed = state.streamed and data.messageId and state.streamed[data.messageId]
  if not streamed and data.content and data.content ~= "" then
    table.insert(events, { kind = "text", delta = data.content })
  end
end

by_type["tool.execution_start"] = function(msg, events, state)
  local data = msg.data or {}
  table.insert(events, {
    kind = "tool_start",
    id = call_id(data, state),
    name = data.toolName or "tool",
    input = arguments_table(data.arguments),
  })
end

by_type["tool.execution_complete"] = function(msg, events, state)
  local data = msg.data or {}
  local id = data.toolCallId and tostring(data.toolCallId) or state.last_anonymous_id
  if not id then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = id,
    result = M.extract_result_text(data),
    is_error = data.success == false,
  })
end

by_type["result"] = function(msg, events)
  if msg.sessionId then
    table.insert(events, { kind = "session", session_id = msg.sessionId })
  end
end

by_type["error"] = function(msg, events)
  local message = msg.message or (msg.data and msg.data.message)
  if message ~= nil then
    local text = M.stringify_message(message)
    if text ~= "" then
      table.insert(events, { kind = "error", message = text })
    end
  end
end

--- @param msg table one decoded JSONL line
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}
  local handler = by_type[msg.type]
  if handler then
    handler(msg, events, state)
  end
  return events
end

return M
