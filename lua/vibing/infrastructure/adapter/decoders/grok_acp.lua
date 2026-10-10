--- `grok agent stdio` session-update notifications, as canonical events.
---
--- A **second** grok decoder, not a replacement for `grok_streaming_json.lua`. The two formats are
--- unrelated: `--output-format streaming-json` emits flat `{"type":"text","data":"hi"}` lines, while
--- the resident agent speaks Agent Client Protocol JSON-RPC and wraps everything in a
--- `params.update` envelope with a `sessionUpdate` discriminator -- carried on two methods, see
--- `UPDATE_METHODS`. Measured against grok 1.0.50 by capturing
--- both from one machine; the `--help` wording ("one ACP session update per line") describes the
--- one-shot stream's *lineage*, not its shape. Same split as codex's `codex_exec_json` /
--- `codex_app_server` pair.
---
--- **This decoder never emits `turn_end`, deliberately.** A turn here ends on the JSON-RPC
--- *response* to `session/prompt`, which is correlated to the request by its id, so
--- `grok_duplex_protocol` completes the turn from that reply. The `turn_completed` notification
--- carries a `prompt_id` and arrives for subagent turns too; consuming it would end the user's turn
--- on work nobody asked for — the failure `duplex_turn.ends_this_turn` exists to prevent on claude.
--- grok's protocol removes the ambiguity rather than needing a guard against it.
--- @module vibing.infrastructure.adapter.decoders.grok_acp

local M = {}

--- One JSON object field, or an empty table.
---
--- `x or {}` is not this guard: `vim.json.decode` turns a `null` into `vim.NIL`, which is **truthy**
--- in Lua and is neither indexable nor iterable (`features.md`, where testing the same shape by
--- truthiness is the mistake that routed every message into the subagent buffer). grok sends one
--- measurably — a successful MCP call's `tool_call_update` carries `"content":null`.
--- @param value any
--- @return table
local function obj(value)
  return type(value) == "table" and value or {}
end

--- grok mixes the two key conventions **within one protocol**: `tool_call` and `tool_call_update`
--- are camelCase (`toolCallId`, `rawInput`), while `tool_call_delta_chunk`, `turn_completed`,
--- `pending_interaction` and `response_completed` are snake_case (`tool_call_id`, `prompt_id`).
--- Measured, not inferred, so every read of a shared field goes through here.
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

--- The keys grok puts a tool's own prose under, most specific first. Measured against grok 1.0.50
--- across every `rawOutput` shape the probes captured; `message` / `error` come last because they
--- belong to a failure envelope and the other two to a result.
--- @type string[]
local RAW_OUTPUT_KEYS = { "tool_output_for_prompt", "OkayOutput", "message", "error" }

--- @param tbl table
--- @return string|nil
local function stated_text(tbl)
  for _, key in ipairs(RAW_OUTPUT_KEYS) do
    if type(tbl[key]) == "string" then
      return tbl[key]
    end
  end
  return nil
end

--- `rawOutput`'s prose, wherever this tool's variant put it.
---
--- **Two of the three measured success shapes nest it one level down**, under a key naming the
--- variant rather than the content: an edit answers
--- `{ type = "SearchReplace", EditsApplied = { tool_output_for_prompt = ... } }` and an MCP call
--- `{ type = "MCP", tool_name = ..., output = { OkayOutput = ... } }`, while only a failure states
--- it at the top (`{ error = ..., message = ... }`). So the descent is the ordinary case, not a
--- fallback. One level only, and the member names are sorted — grok has never sent two of them, and
--- `pairs` order would otherwise decide which won.
--- @param raw any
--- @return string|nil
local function raw_output_text(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local text = stated_text(raw)
  if text then
    return text
  end

  local names = {}
  for name, value in pairs(raw) do
    if type(value) == "table" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    text = stated_text(raw[name])
    if text then
      return text
    end
  end
  return nil
end

--- The text a finished tool call should show.
---
--- `content` is a list of blocks and only the `content` ones carry prose; a `diff` block is the
--- same edit the per-request git snapshot already renders, so repeating it here would print the
--- patch twice. `rawOutput` is what a tool that reported no block at all says instead — which is
--- every successful edit (`content` is the diff) and every successful MCP call (`content` is
--- `null`).
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
  return raw_output_text(update.rawOutput)
end

--- The two methods grok carries its updates on, both with the same `params.update` envelope.
---
--- **The split is not by kind and not by stability.** Measured against grok 1.0.50: the standard
--- ACP `session/update` carries `agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
--- `tool_call_update`, `available_commands_update` and `session_info_update`, while the vendor
--- `_x.ai/session_notification` carries `response_completed`, `model_changed`, `hook_annotation`,
--- `hook_run_started`, `hook_execution`, `pending_interaction`, `interaction_resolved`,
--- `tool_call_delta_chunk` and `turn_completed`. Reading only the standard one left the usage, the
--- model and the hook's refusal notice as dead handlers -- a turn rendered its prose and its tool
--- calls correctly and reported no tokens at all, which is why this is measured from a live run
--- rather than taken from the protocol's own vocabulary.
--- @type table<string, boolean>
local UPDATE_METHODS = {
  ["session/update"] = true,
  ["_x.ai/session_notification"] = true,
}

local by_update = {}

by_update.agent_message_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "text", delta = obj(update.content).text or "" })
end

by_update.agent_thought_chunk = function(update, events)
  table.insert(events, { kind = "first_response" })
  table.insert(events, { kind = "thinking", delta = obj(update.content).text or "" })
end

--- grok names the tool twice and the two spellings differ: `_meta["x.ai/tool"].name` is the native
--- id the vocabulary and the permission rules speak (`write`), while `title` is prose meant for a
--- human and becomes `Write `/path`` on the very next update. Taking the title would hand
--- `event_renderer` a name no `grok_tool_vocabulary` entry can match.
by_update.tool_call = function(update, events)
  local id = either(update, "toolCallId", "tool_call_id")
  if not id then
    return
  end
  local meta = obj(obj(update._meta)["x.ai/tool"])
  table.insert(events, { kind = "first_response" })
  table.insert(events, {
    kind = "tool_start",
    id = tostring(id),
    name = meta.name or update.title or "unknown",
    input = obj(update.rawInput),
  })
end

--- ACP's two terminal `ToolCallStatus` values. The other two (`pending`, `in_progress`) are
--- progress, and grok measurably sends `in_progress` **twice** for one `run_terminal_command` --
--- once empty and once with the output so far -- so "has a status" is not the terminal test. Keying
--- on presence closed the call three times: the result was rendered before the command had output,
--- and twice more after.
---
--- An unrecognised status is therefore treated as progress and leaves the call open. That is the
--- lesser failure of the two: a call closed early states a result that is not the result, while one
--- left open costs the closing line of a tool block whose output has already streamed.
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

--- grok's keys here are already the ones `TokenUsage.record` reads, so the payload is passed
--- through rather than translated. Per response, not cumulative -- the `_meta.usage` block on the
--- `session/prompt` reply is the running total for the whole session and would double-count.
by_update.response_completed = function(update, events)
  if type(update.usage) == "table" then
    table.insert(events, { kind = "usage", record = update.usage })
  end
end

--- What a hook decided, in grok's own words (`write` blocked by plugin/...`). The permission gate
--- itself is vibing's; this is the only place the CLI says out loud that a tool was refused, and
--- without it a denied call looks to the user like a turn that simply did nothing.
by_update.hook_annotation = function(update, events)
  if update.message then
    table.insert(events, { kind = "error", message = tostring(update.message) })
  end
end

by_update.model_changed = function(update, events)
  local model = either(update, "modelId", "model_id")
  if model then
    table.insert(events, { kind = "cli_info", model = tostring(model) })
  end
end

by_update.available_commands_update = function(update, events)
  local tools = obj(update._meta).tools
  if type(tools) == "table" then
    table.insert(events, { kind = "cli_info", tools = #tools })
  end
end

--- @param msg table one decoded JSON-RPC frame
--- @param state table
--- @return Vibing.CanonicalEvent[]
function M.decode(msg, state)
  local events = {}
  local params = obj(msg.params)

  -- Synthesised by `grok_duplex_protocol` once the session is named, because the id arrives in a
  -- `session/new` / `session/load` *reply* rather than in any notification.
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
  if not UPDATE_METHODS[msg.method] then
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
