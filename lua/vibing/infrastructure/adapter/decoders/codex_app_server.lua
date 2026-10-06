--- App-server notifications -> canonical events, using exec's tool rendering contract.
local Exec = require("vibing.infrastructure.adapter.decoders.codex_exec_json")
local TokenUsage = require("vibing.core.utils.token_usage")
local M = {}
local TYPES = {
  commandExecution = "command_execution",
  fileChange = "file_change",
  mcpToolCall = "mcp_tool_call",
  webSearch = "web_search",
}
local function exec_item(item)
  local mapped =
    vim.tbl_extend("force", item, { type = TYPES[item.type] or item.type, aggregated_output = item.aggregatedOutput })
  if item.type == "fileChange" then
    mapped.changes = {}
    for _, change in ipairs(item.changes or {}) do
      table.insert(
        mapped.changes,
        { path = change.path, kind = type(change.kind) == "table" and change.kind.type or change.kind }
      )
    end
  end
  return mapped
end

--- The two item types whose body arrives twice: once as deltas while it is produced, and again
--- whole on `item/completed`. Rendering both shows the block twice, so a delta marks its item and
--- the completion re-emits only what never streamed (a turn that produced no delta at all -- a
--- short answer, or a resumed thread replaying an item -- still has to render from the completion).
---
--- `emits_empty` is the one thing the two do not share: an agent message renders even with no text
--- (it is the whole answer, and the renderer wants the block opened), while an empty reasoning
--- body is nothing to show.
local STREAMING = {
  agentMessage = { kind = "text", emits_empty = true },
  reasoning = { kind = "thinking", emits_empty = false },
}

--- Remember that this item's body already reached the renderer as deltas.
local function mark_streamed(state, item_id)
  if item_id ~= nil then
    state.streamed_items = state.streamed_items or {}
    state.streamed_items[item_id] = true
  end
end

--- Whether this item streamed, clearing the mark: one item completes once, and the table must not
--- grow for the life of a resident process. `start_turn` clears what is left of it per turn.
local function take_streamed(state, item_id)
  local streamed = state.streamed_items and state.streamed_items[item_id]
  if state.streamed_items then
    state.streamed_items[item_id] = nil
  end
  return streamed
end

function M.decode(msg, state)
  local p, method = msg.params or {}, msg.method
  if method == "thread/started" then
    local id = p.thread and p.thread.id
    if id and state.session_id ~= id then
      state.session_id = id
      return { { kind = "session", session_id = id } }
    end
  elseif method == "turn/started" then
    return { { kind = "first_response" } }
  elseif method == "item/agentMessage/delta" then
    mark_streamed(state, p.itemId)
    return { { kind = "text", delta = p.delta or "" } }
  elseif method == "item/reasoning/summaryTextDelta" or method == "item/reasoning/textDelta" then
    mark_streamed(state, p.itemId)
    return { { kind = "thinking", delta = p.delta or "" } }
  elseif method == "item/started" or method == "item/completed" then
    local item = p.item
    if not item then
      return {}
    end
    local streaming = STREAMING[item.type]
    if streaming then
      local text = item.text or ""
      if method == "item/completed" and not take_streamed(state, item.id) and (streaming.emits_empty or text ~= "") then
        return { { kind = streaming.kind, delta = text } }
      end
      return {}
    end
    return Exec.decode(
      { type = method == "item/started" and "item.started" or "item.completed", item = exec_item(item) },
      state
    )
  elseif method == "thread/tokenUsage/updated" then
    local total = p.tokenUsage and p.tokenUsage.total
    if total then
      return {
        {
          kind = "usage",
          accumulator = TokenUsage.cumulative({
            input = total.inputTokens,
            cached = total.cachedInputTokens,
            output = total.outputTokens,
            reasoning = total.reasoningOutputTokens,
          }),
        },
      }
    end
  elseif method == "turn/completed" then
    local turn, events = p.turn or {}, {}
    if turn.status ~= "completed" then
      table.insert(events, {
        kind = "error",
        fatal = true,
        message = turn.status == "interrupted" and "Cancelled"
          or (turn.error and turn.error.message)
          or "Codex turn failed",
      })
    end
    table.insert(events, { kind = "turn_end" })
    return events
  elseif method == "vibing/requestDenied" then
    return { { kind = "error", message = p.message } }
  end
  return {}
end
return M
