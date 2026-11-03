--- `commandcode acp` session-update notifications, as canonical events.
---
--- Standard Agent Client Protocol over stdio — the same family `opencode acp` and grok's `agent
--- stdio` speak, and a third decoder for it rather than a shared one for the same reason those two
--- are separate: what each agent puts in an update differs. Command Code's difference is that a
--- `tool_call` carries **no native tool name at all**, only a prose `title` ("Shell: echo hi") and
--- a coarse `kind` (`read`/`edit`/`execute`/`search`/`fetch`). The kind is what the renderer names
--- the call by, which is why `commandcode_tool_vocabulary.to_canonical` maps it.
---
--- **This decoder never emits `turn_end`.** A turn ends on the JSON-RPC *response* to
--- `session/prompt`, which is correlated to the request by id, so `commandcode_duplex_protocol`
--- completes the turn from that reply. Emitting a `turn_end` here would have no line to hang it on.
---
--- Measured against Command Code 1.88.2 — see `tests/fixtures/streams/commandcode/`.
--- @module vibing.infrastructure.adapter.decoders.commandcode_acp

local M = {}

--- One JSON object field, or an empty table.
---
--- `x or {}` is not this guard: `vim.json.decode` turns a `null` into `vim.NIL`, which is truthy
--- in Lua and neither indexable nor iterable, so an empty `content` (Command Code sends one on a
--- successful read) would raise.
--- @param value any
--- @return table
local function obj(value)
  return type(value) == "table" and value or {}
end

--- The prose a finished tool call should show.
--- `content` is a list of blocks and only the `content` ones carry text; a `diff` block is the same
--- edit the per-request git snapshot already renders.
--- @param update table
--- @return string|nil
local function tool_result_text(update)
  local parts = {}
  for _, block in ipairs(obj(update.content)) do
    if block.type == "content" and type(block.content) == "table" and block.content.text then
      table.insert(parts, tostring(block.content.text))
    end
  end
  if #parts > 0 then
    return table.concat(parts, "\n")
  end
  return nil
end

--- ACP's two terminal `ToolCallStatus` values. `pending`/`in_progress` are progress — Command Code
--- measurably sends `in_progress` more than once per call — so "has a status" is not the test.
--- @type table<string, boolean>
local TERMINAL_STATUS = { completed = true, failed = true }

local by_update = {}

by_update.agent_message_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "text", delta = obj(update.content).text or "" })
end

by_update.agent_thought_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "thinking", delta = obj(update.content).text or "" })
end

--- The tool's native name is not on the wire; the `kind` is what the vocabulary maps. `title` is
--- the fallback for a call that reported no kind, and is prose rather than a name — acceptable
--- only because it is the last resort.
by_update.tool_call = function(update, events)
  if not update.toolCallId then
    return
  end
  table.insert(events, { kind = "first_response" })
  table.insert(events, {
    kind = "tool_start",
    id = tostring(update.toolCallId),
    name = update.kind or update.title or "tool",
    input = obj(update.rawInput),
  })
end

by_update.tool_call_update = function(update, events)
  local status = update.status
  if type(status) ~= "string" or not TERMINAL_STATUS[status:lower()] then
    return
  end
  if not update.toolCallId then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = tostring(update.toolCallId),
    result = tool_result_text(update),
    is_error = status:lower() == "failed",
  })
end

--- The context window gauge (`used`/`size`), not the bill — token counts ride the `session/prompt`
--- reply, which the protocol folds in. Reported as `cli_info` so nothing is invented for tokens.
by_update.usage_update = function(update, events)
  if type(update.cost) == "table" and type(update.cost.amount) == "number" then
    table.insert(events, { kind = "cli_info" })
  end
end

by_update.available_commands_update = function(update, events)
  if type(update.availableCommands) == "table" then
    table.insert(events, { kind = "cli_info", tools = #update.availableCommands })
  end
end

--- @param msg table one decoded JSON-RPC frame
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}
  local params = obj(msg.params)

  -- Synthesised by `commandcode_duplex_protocol` as it writes `session/prompt`. Until then
  -- `session/load` re-emits stored updates into an already-open turn, which would reprint the prior
  -- conversation into the new Assistant. `decoder_state` is per process, so a later turn on the
  -- same agent keeps this open.
  if msg.method == "vibing/promptStarted" then
    state.prompt_open = true
    return events
  end

  -- Synthesised once the session id is known, because it arrives in a `session/new` reply rather
  -- than in any notification.
  if msg.method == "vibing/sessionStarted" then
    if params.session_id and state.session_id ~= params.session_id then
      state.session_id = params.session_id
      table.insert(events, { kind = "session", session_id = params.session_id })
    end
    return events
  end
  if msg.method == "vibing/requestDenied" then
    table.insert(events, { kind = "error", message = params.message })
    return events
  end

  if msg.method ~= "session/update" then
    return events
  end
  if not state.prompt_open then
    return events
  end

  local update = params.update
  if type(update) ~= "table" then
    return events
  end
  local handler = by_update[update.sessionUpdate]
  if handler then
    handler(update, events, state)
  end
  return events
end

return M
