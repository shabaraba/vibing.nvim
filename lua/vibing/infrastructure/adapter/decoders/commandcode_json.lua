--- `commandcode -p --output-format json` (NDJSON), as canonical events.
---
--- Two envelopes share one stream. Most lines are `{"type":"event","event":{...}}`; the last is
--- `{"type":"result",...}`, which carries the run's verdict and is the only line that says the run
--- is over. Measured against Command Code 1.88.2 — see `tests/fixtures/streams/commandcode/`.
---
--- Usage is reported **per request** (`model_request_end`), not as a running total, so it is
--- accumulated the way claude's is rather than wrapped in a cumulative accumulator. The
--- `run_end`/`result` totals are the whole run and are deliberately not recorded — folding them in
--- with the per-request records would count every request twice.
--- @module vibing.infrastructure.adapter.decoders.commandcode_json

local M = {}

--- Command Code's own usage field names onto the ones `TokenUsage.record` reads.
---
--- `inputTokens` **includes** the cached read (measured on the ACP reply, where
--- `totalTokens == inputTokens + outputTokens`), so the cached share is subtracted out the way
--- claude's and OpenCode's are — `TokenUsage.record` adds the cache fields back itself, and
--- leaving it in would count every cached token twice.
--- @param usage table
--- @return table
local function usage_record(usage)
  local input = tonumber(usage.inputTokens) or 0
  local cached = tonumber(usage.cacheReadTokens) or 0
  return {
    input_tokens = math.max(0, input - cached),
    cache_read_input_tokens = cached,
    cache_creation_input_tokens = usage.cacheWriteTokens or 0,
  }
end

--- The prose a `tool_completed` result carries: a list of text blocks, or "" when empty.
--- @param result any
--- @return string
local function result_text(result)
  local parts = {}
  if type(result) == "table" then
    for _, block in ipairs(result) do
      if type(block) == "table" and type(block.text) == "string" then
        table.insert(parts, block.text)
      end
    end
  elseif type(result) == "string" then
    return result
  end
  return table.concat(parts, "\n")
end

local by_type = {}

by_type.run_start = function(event, events, state)
  state.session_id = event.sessionId
  table.insert(events, { kind = "session", session_id = event.sessionId })
end

by_type.text_delta = function(event, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "text", delta = event.delta or "" })
end

by_type.thinking_delta = function(event, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "thinking", delta = event.delta or "" })
end

by_type.tool_queued = function(event, events)
  if not event.toolCallId then
    return
  end
  table.insert(events, { kind = "first_response" })
  table.insert(events, {
    kind = "tool_start",
    id = tostring(event.toolCallId),
    name = event.toolName or "tool",
    input = event.input or {},
  })
end

by_type.tool_completed = function(event, events)
  if not event.toolCallId then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = tostring(event.toolCallId),
    result = result_text(event.result),
    is_error = false,
  })
end

--- A tool the CLI itself refused, or a PreToolUse hook blocked. There is no `tool_running` /
--- `tool_completed` after it, so this is the only line that closes the call the `tool_queued`
--- opened — without it the chat would leave the header open forever.
by_type.tool_hook_blocked = function(event, events)
  if not event.toolCallId then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = tostring(event.toolCallId),
    result = event.hookOutput or "Blocked.",
    is_error = true,
  })
end

by_type.tool_errored = function(event, events)
  if not event.toolCallId then
    return
  end
  local message = event.error
  if type(message) == "table" then
    message = message.message or message.name
  end
  table.insert(events, {
    kind = "tool_end",
    id = tostring(event.toolCallId),
    result = tostring(message or "Tool failed."),
    is_error = true,
  })
end

by_type.model_request_end = function(event, events)
  if type(event.usage) == "table" then
    table.insert(events, { kind = "usage", record = usage_record(event.usage) })
  end
  if event.model then
    table.insert(events, { kind = "cli_info", model = event.model })
  end
end

--- The run failed before the final line (a transport error, a plan rejection). `run_end` follows
--- with the same verdict, and the `result` line repeats it a third time; the renderer drops an
--- immediate repeat, so all three are emitted for whichever order the CLI chooses.
by_type.run_error = function(event, events)
  local raw = event.error
  local message = type(raw) == "table" and (raw.message or raw.name) or raw
  if message ~= nil then
    table.insert(events, { kind = "error", message = tostring(message), fatal = true })
  end
end

--- @param msg table one decoded JSON line
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}

  if msg.type == "result" then
    if type(msg.error) == "string" and msg.error ~= "" then
      table.insert(events, { kind = "error", message = msg.error, fatal = true })
    end
    table.insert(events, { kind = "turn_end", subtype = msg.subtype })
    return events
  end

  if msg.type ~= "event" or type(msg.event) ~= "table" then
    return events
  end
  local event = msg.event
  local handler = by_type[event.type]
  if handler then
    handler(event, events, state)
  end
  return events
end

return M
