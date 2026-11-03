--- `opencode run --format json` (JSONL), as canonical events.
--- @module vibing.infrastructure.adapter.decoders.opencode_json

local M = {}

local function session_id(msg)
  return msg.sessionID or msg.session_id
end

local by_type = {}

by_type["step_start"] = function(_, events, state)
  if not state.announced_first_response then
    state.announced_first_response = true
    table.insert(events, { kind = "first_response" })
  end
end

by_type["reasoning"] = function(msg, events)
  local part = msg.part
  if type(part) == "table" and part.text then
    table.insert(events, { kind = "thinking", delta = part.text })
  end
end

by_type["text"] = function(msg, events)
  local part = msg.part
  if type(part) == "table" and part.text then
    table.insert(events, { kind = "text", delta = part.text })
  end
end

by_type["tool_use"] = function(msg, events)
  local part = msg.part
  if type(part) ~= "table" then
    return
  end
  local state = part.state or {}
  local input = type(state.input) == "table" and state.input or {}
  table.insert(events, {
    kind = "tool_start",
    id = part.id,
    name = part.tool or "tool",
    input = input,
  })
  local result = state.output
  if result == nil then
    result = state.error
  end
  if type(result) ~= "string" then
    if result ~= nil then
      local ok, enc = pcall(vim.json.encode, result)
      result = ok and enc or tostring(result)
    else
      result = ""
    end
  end
  table.insert(events, {
    kind = "tool_end",
    id = part.id,
    result = result,
    is_error = state.status ~= "completed" or state.error ~= nil,
  })
end

by_type["step_finish"] = function(msg, events)
  local part = msg.part or {}
  local tokens = part.tokens
  if type(tokens) == "table" then
    local cache = tokens.cache or {}
    table.insert(events, {
      kind = "usage",
      record = {
        input_tokens = tokens.input or 0,
        cache_read_input_tokens = cache.read or 0,
        cache_creation_input_tokens = cache.write or 0,
      },
    })
  end
  if part.reason == "stop" or part.reason == "end_turn" then
    table.insert(events, { kind = "turn_end" })
  end
end

by_type["error"] = function(msg, events)
  local err = msg.error
  local message
  if type(err) == "table" then
    message = err.message or err.type
  else
    message = err
  end
  if message ~= nil then
    table.insert(events, { kind = "error", message = tostring(message), fatal = true })
  end
end

function M.decode(msg, state)
  local events = {}
  local sid = session_id(msg)
  if type(sid) == "string" and sid ~= "" and sid ~= state.session_id then
    state.session_id = sid
    table.insert(events, { kind = "session", session_id = sid })
  end
  local handler = by_type[msg.type]
  if handler then
    handler(msg, events, state)
  end
  return events
end

return M
