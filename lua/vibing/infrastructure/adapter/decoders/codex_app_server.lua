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
    state.text_items = state.text_items or {}
    state.text_items[p.itemId] = true
    return { { kind = "text", delta = p.delta or "" } }
  elseif method == "item/reasoning/summaryTextDelta" or method == "item/reasoning/textDelta" then
    return { { kind = "thinking", delta = p.delta or "" } }
  elseif method == "item/started" or method == "item/completed" then
    local item = p.item
    if not item then
      return {}
    end
    if item.type == "agentMessage" then
      if method == "item/completed" then
        local streamed = state.text_items and state.text_items[item.id]
        if state.text_items then
          state.text_items[item.id] = nil
        end
        if not streamed then
          return { { kind = "text", delta = item.text or "" } }
        end
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
      table.insert(
        events,
        {
          kind = "error",
          fatal = true,
          message = turn.status == "interrupted" and "Cancelled"
            or (turn.error and turn.error.message)
            or "Codex turn failed",
        }
      )
    end
    table.insert(events, { kind = "turn_end" })
    return events
  elseif method == "vibing/requestDenied" then
    return { { kind = "error", message = p.message } }
  end
  return {}
end
return M
