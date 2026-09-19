--- `claude -p --output-format stream-json --include-partial-messages`, as canonical events.
---
--- The reference decoder: what it emits is what every other backend is rendered to look like.
--- Shapes captured from claude 2.1.x; `tests/fixtures/streams/claude/` holds real captures.
--- @module vibing.infrastructure.adapter.decoders.claude_stream_json

local M = {}

--- The id of the tool call a message belongs to, or nil for the parent's own messages.
---
--- Top-level messages carry `"parent_tool_use_id": null`, which vim.json.decode turns into
--- `vim.NIL` -- truthy in Lua. Testing the field directly would classify every ordinary assistant
--- message as subagent output and stop tool results from rendering at all.
--- @param msg table
--- @return string|nil
local function parent_tool_use_id(msg)
  local id = msg.parent_tool_use_id
  return type(id) == "string" and id ~= "" and id or nil
end

--- @param content any a tool_result block's content
--- @return string
local function result_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, c in ipairs(content) do
      if type(c) == "table" and c.text then
        table.insert(parts, c.text)
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

--- @param value any
--- @return number|nil
local function count_of(value)
  return type(value) == "table" and #value or nil
end

--- Only `text` blocks: thinking blocks are not what the reader asked to see.
--- @param message table
--- @return string
local function text_blocks(message)
  local parts = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "text" and block.text then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "")
end

--- @param events Vibing.CanonicalEvent[]
--- @param message table
local function tool_blocks(events, message)
  for _, block in ipairs(message.content or {}) do
    if block.type == "tool_use" and block.id then
      table.insert(events, { kind = "tool_start", id = block.id, name = block.name, input = block.input or {} })
    elseif block.type == "tool_result" and block.tool_use_id then
      table.insert(events, { kind = "tool_end", id = block.tool_use_id, result = result_text(block.content) })
    end
  end
end

local by_type = {}

--- `init` is the only place the CLI states its own version and how many tools and MCP servers it
--- loaded, and `compact_boundary` is the only signal that the conversation was compacted -- both
--- die with the process, so they are carried out as `cli_info`.
by_type.system = function(msg, events)
  if msg.subtype == "init" then
    table.insert(events, {
      kind = "cli_info",
      version = msg.claude_code_version,
      model = msg.model,
      tools = count_of(msg.tools),
      mcp_servers = count_of(msg.mcp_servers),
    })
  elseif msg.subtype == "compact_boundary" then
    table.insert(events, { kind = "cli_info", compacted = true })
  end
  -- The first system event proves the CLI is alive.
  table.insert(events, { kind = "first_response" })
end

by_type.stream_event = function(msg, events)
  local event = msg.event
  if event and event.type == "content_block_delta" and event.delta then
    local delta = event.delta
    if delta.type == "text_delta" and delta.text then
      table.insert(events, { kind = "text", delta = delta.text })
    end
  end
end

--- Verified against the CLI: with --forward-subagent-text, a subagent's contribution arrives as
--- complete `assistant`/`user` events carrying a top-level `parent_tool_use_id` -- never as
--- `stream_event` deltas. So the parent's streaming text is untouched, and the subagent's output is
--- held (by the renderer) until its tool_result lands.
by_type.assistant = function(msg, events)
  local message = msg.message
  if not message then
    return
  end
  local subagent_of = parent_tool_use_id(msg)

  -- Recorded before the subagent bail-out below, because a subagent's requests cost real tokens
  -- even though its context is its own.
  if message.usage then
    table.insert(events, { kind = "usage", record = message.usage, subagent = subagent_of ~= nil })
  end

  if subagent_of then
    local text = text_blocks(message)
    if text ~= "" then
      table.insert(events, { kind = "subagent_text", parent_id = subagent_of, text = text })
    end
    return
  end

  tool_blocks(events, message)
end

--- A subagent's `user` events belong to its transcript, not the parent's: the prompt echo the
--- parent already showed in the tool header, and its own nested tool results.
by_type.user = function(msg, events)
  if parent_tool_use_id(msg) or not msg.message then
    return
  end
  tool_blocks(events, msg.message)
end

--- The end of a turn, whether or not it succeeded.
---
--- Under the oneshot transport this is redundant — the process exits, and that exit is what
--- completes the turn. A resident process exits at the end of the *session*, so `result` is the
--- only thing that says a turn is over, and it is also the boundary the per-turn half of the event
--- context (`tokenUsage` / `cliInfo` / `resultErrors` / `output`) is cut on.
by_type.result = function(msg, events)
  if msg.subtype == "error" or msg.is_error then
    table.insert(events, { kind = "error", message = msg.result or "Unknown error", fatal = true })
  end
  table.insert(events, { kind = "turn_end", subtype = msg.subtype })
end

--- Error/unknown-command responses that bypass streaming.
by_type.text = function(msg, events)
  if msg.text then
    table.insert(events, { kind = "text", delta = msg.text })
  end
end

--- Emitted mid-stream both as a remaining-quota warning and when a request is actually turned
--- away; the renderer merges them.
by_type.rate_limit_event = function(msg, events)
  local info = require("vibing.core.utils.rate_limit").from_event(msg)
  if info then
    table.insert(events, { kind = "rate_limit", info = info })
  end
end

--- @param msg table one decoded stream-json line
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}

  -- Every line carries the session id; report it when it first appears or changes.
  if type(msg.session_id) == "string" and msg.session_id ~= state.session_id then
    state.session_id = msg.session_id
    table.insert(events, { kind = "session", session_id = msg.session_id })
  end

  local handler = by_type[msg.type]
  if handler then
    handler(msg, events, state)
  end
  return events
end

return M
