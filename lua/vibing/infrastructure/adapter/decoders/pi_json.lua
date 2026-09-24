--- `pi --mode json` (the JSONL session-event stream), as canonical events.
---
--- Shapes captured from Pi 0.87.1 against a local `mlx_lm.server`, not read off its documentation.
--- The captures are `tests/fixtures/streams/pi/`.
---
--- Two shapes here are not what the documentation suggests, and both would fail quietly:
---
--- **`turn_end` is not the end of the request.** Pi emits `turn_start`/`turn_end` once per *model*
--- turn, so a request that calls a tool emits two of each. `agent_settled` is the one terminal
--- record, and it is what this decoder maps to the canonical `turn_end`. Mapping Pi's own
--- `turn_end` would declare the turn finished while the tool result was still being answered.
---
--- **Usage is per assistant message, not per turn and not cumulative.** It rides on every
--- `message_update` as well, growing within a message, so recording those would multiply-count by
--- the number of deltas. Only the `message_end` of an assistant message carries the settled figure,
--- which is why that is the only place usage is read.
--- @module vibing.infrastructure.adapter.decoders.pi_json

local M = {}

--- Pi's tool results are MCP-style content blocks: `{content = {{type = "text", text = "..."}}}`.
--- @param result any
--- @return string
local function result_text(result)
  if type(result) == "table" and type(result.content) == "table" then
    local parts = {}
    for _, block in ipairs(result.content) do
      if type(block) == "table" and block.text then
        table.insert(parts, tostring(block.text))
      elseif type(block) == "string" then
        table.insert(parts, block)
      end
    end
    return table.concat(parts, "")
  elseif type(result) == "table" then
    local ok, encoded = pcall(vim.json.encode, result)
    return ok and encoded or vim.inspect(result)
  elseif result ~= nil then
    return tostring(result)
  end
  return ""
end

--- The first content of a request cancels the resume watchdog. Emitted once per stream rather than
--- on every `turn_start`, because a request with a tool call has several of those.
--- @param events Vibing.CanonicalEvent[]
--- @param state table
local function first_response_once(events, state)
  if state.announced_first_response then
    return
  end
  state.announced_first_response = true
  table.insert(events, { kind = "first_response" })
end

--- Pi's per-message usage in the field names `TokenUsage.record` reads. Pi has no counter for
--- reasoning tokens separate from `output`, and `record` tracks only the three that make up the
--- context size, so nothing is lost by the omission.
--- @param usage table
--- @return table
local function usage_record(usage)
  return {
    input_tokens = usage.input,
    cache_read_input_tokens = usage.cacheRead,
    cache_creation_input_tokens = usage.cacheWrite,
  }
end

--- Streaming pieces of one assistant message, keyed by `assistantMessageEvent.type`.
--- @type table<string, fun(ae: table, events: Vibing.CanonicalEvent[])>
local by_assistant_event = {
  text_delta = function(ae, events)
    table.insert(events, { kind = "text", delta = ae.delta or "" })
  end,
  thinking_delta = function(ae, events)
    table.insert(events, { kind = "thinking", delta = ae.delta or "" })
  end,
  --- A provider-stream failure, reported inside the message rather than as a top-level record.
  --- Not fatal: Pi may still settle the agent afterwards, and `agent_end.willRetry` is its own
  --- signal. Marking it fatal here would put it in `resultErrors` and report a turn that recovered
  --- as a failed one.
  error = function(ae, events)
    -- `error` is undocumented and has been seen as both a string and an object; `tostring` on the
    -- latter renders "table: 0x..." into the chat, which reads as a vibing.nvim bug rather than a
    -- provider one. Every field of an error payload has to be optional.
    local raw = ae.error
    local message = type(raw) == "table" and (raw.message or raw.error) or raw
    table.insert(events, { kind = "error", message = tostring(message or ae.reason or "Pi reported a stream error") })
  end,
}

local by_type = {}

--- Only `--mode json` writes this record; `--mode rpc` omits it (measured). The id is whatever
--- `--session-id` asked for, or a generated uuid when it asked for nothing.
by_type["session"] = function(msg, events)
  if msg.id then
    table.insert(events, { kind = "session", session_id = msg.id })
  end
end

by_type["agent_start"] = function(_, events, state)
  first_response_once(events, state)
end

by_type["turn_start"] = function(_, events, state)
  first_response_once(events, state)
end

by_type["message_start"] = function(msg, events, state)
  local message = msg.message
  if type(message) ~= "table" or message.role ~= "assistant" then
    return
  end
  -- The model actually serving this request, which for Pi is the one fact a user most needs back:
  -- the model is configured in Pi's own `models.json`, not in vibing's frontmatter, so a chat can
  -- silently be answered by something other than what `model:` says. Announced once per stream.
  if state.announced_model or not message.model then
    return
  end
  state.announced_model = true
  table.insert(events, { kind = "cli_info", model = tostring(message.model) })
end

by_type["message_update"] = function(msg, events)
  local ae = msg.assistantMessageEvent
  if type(ae) ~= "table" then
    return
  end
  local handler = by_assistant_event[ae.type]
  if handler then
    handler(ae, events)
  end
end

by_type["message_end"] = function(msg, events)
  local message = msg.message
  if type(message) ~= "table" or message.role ~= "assistant" or type(message.usage) ~= "table" then
    return
  end
  table.insert(events, { kind = "usage", record = usage_record(message.usage) })
end

by_type["tool_execution_start"] = function(msg, events)
  if not msg.toolCallId then
    return
  end
  table.insert(events, {
    kind = "tool_start",
    id = msg.toolCallId,
    name = msg.toolName or "tool",
    input = type(msg.args) == "table" and msg.args or {},
  })
end

by_type["tool_execution_end"] = function(msg, events)
  if not msg.toolCallId then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = msg.toolCallId,
    result = result_text(msg.result),
    is_error = msg.isError == true,
  })
end

--- The one terminal record. See the module comment for why Pi's own `turn_end` is not it.
by_type["agent_settled"] = function(_, events)
  table.insert(events, { kind = "turn_end" })
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
