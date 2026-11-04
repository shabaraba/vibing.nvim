--- `opencode acp` session-update notifications, as canonical events.
---
--- The resident agent speaks standard Agent Client Protocol: everything is wrapped in a
--- `params.update` envelope with a `sessionUpdate` discriminator on `session/update`.
---
--- **This decoder never emits `turn_end`, deliberately.** A turn ends on the JSON-RPC *response* to
--- `session/prompt`, which is correlated to the request by its id, so
--- `opencode_duplex_protocol` completes the turn from that reply. There is no line here to hang a
--- `turn_end` on.
--- @module vibing.infrastructure.adapter.decoders.opencode_acp

local M = {}

--- One JSON object field, or an empty table.
---
--- `x or {}` is not this guard: `vim.json.decode` turns a `null` into `vim.NIL`, which is **truthy**
--- in Lua and is neither indexable nor iterable (`features.md`, where testing the same shape by
--- truthiness is the mistake that routed every message into the subagent buffer). A successful MCP
--- call can send `"content":null`.
--- @param value any
--- @return table
local function obj(value)
  return type(value) == "table" and value or {}
end

--- ACP's `tool_call` / `tool_call_update` fields are camelCase (`toolCallId`, `rawInput`). A
--- snake_case variant is still read because the field has been sent both ways by ACP clients.
--- @param update table
--- @param camel string
--- @param snake string
--- @return any
local function either(update, camel, snake)
  local value = update[camel]
  if value == nil then
    return update[snake]
  end
  return value
end

--- The text a finished tool call should show.
---
--- `content` is a list of blocks and only the `content` ones carry prose; a `diff` block is the
--- same edit the per-request git snapshot already renders, so repeating it here would print the
--- patch twice.
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
  if type(update.rawOutput) == "string" then
    return update.rawOutput
  end
  return nil
end

local by_update = {}

by_update.agent_message_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "text", delta = obj(update.content).text or "" })
end

by_update.agent_thought_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "thinking", delta = obj(update.content).text or "" })
end

--- OpenCode names the tool twice: `name` is the native id the vocabulary and the permission rules
--- speak (`read`, `write`), while `title` is prose meant for a human. Taking the title first would
--- hand `event_renderer` a name no vocabulary entry can match.
by_update.tool_call = function(update, events)
  local id = either(update, "toolCallId", "tool_call_id")
  if not id then
    return
  end
  table.insert(events, { kind = "first_response" })
  table.insert(events, {
    kind = "tool_start",
    id = tostring(id),
    name = update.name or update.title or "unknown",
    input = obj(update.rawInput),
  })
end

--- ACP's two terminal `ToolCallStatus` values. `pending` and `in_progress` are progress, so "has a
--- status" is not the terminal test.
---
--- An unrecognised status is treated as progress and leaves the call open. That is the lesser
--- failure of the two: a call closed early states a result that is not the result, while one left
--- open costs the closing line of a tool block whose output has already streamed.
--- @type table<string, boolean>
local TERMINAL_STATUS = { completed = true, failed = true }

--- Several messages share this name: the terminal one, the progress ones, and an enrichment with no
--- status at all that arrives mid-call to add the title, the locations and the diff.
by_update.tool_call_update = function(update, events)
  local status = update.status
  if type(status) ~= "string" or not TERMINAL_STATUS[status:lower()] then
    return
  end
  local id = either(update, "toolCallId", "tool_call_id")
  if not id then
    return
  end
  table.insert(events, {
    kind = "tool_end",
    id = tostring(id),
    result = tool_result_text(update),
    is_error = status:lower() == "failed",
  })
end

--- @param msg table one decoded JSON-RPC frame
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}
  local params = obj(msg.params)

  -- Synthesised by `opencode_duplex_protocol` as it writes `session/prompt`. Until then,
  -- `session/load` re-emits stored updates into an already-open turn, which would reprint the prior
  -- conversation into the new Assistant. `decoder_state` is per process, so a later turn on the
  -- same agent keeps this open.
  if msg.method == "vibing/promptStarted" then
    state.prompt_open = true
    return events
  end

  -- Synthesised by `opencode_duplex_protocol` once the session is named, because the id arrives in
  -- a `session/new` / `session/load` *reply* rather than in any notification.
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
