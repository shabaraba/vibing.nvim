--- `grok --output-format streaming-json`, as canonical events.
---
--- Shapes captured from grok 0.2.101. The stream carries text and thought deltas, an `end` event
--- with the session id, and errors -- no tool events, so tool calls are not rendered on grok.
--- @module vibing.infrastructure.adapter.decoders.grok_streaming_json

local M = {}

local by_type = {}

--- Confirmed via real CLI: "thought" arrives as many small word-by-word deltas.
by_type.thought = function(msg, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "thinking", delta = msg.data or "" })
end

by_type.text = function(msg, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "text", delta = msg.data or "" })
end

--- Grok's headless output has no dedicated session-start event; sessionId is only known once the
--- turn ends. Completion itself is process-exit driven.
by_type["end"] = function(msg, events)
  if msg.sessionId then
    table.insert(events, { kind = "session", session_id = msg.sessionId })
  end
end

by_type.error = function(msg, events)
  if msg.message then
    table.insert(events, { kind = "error", message = tostring(msg.message) })
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
