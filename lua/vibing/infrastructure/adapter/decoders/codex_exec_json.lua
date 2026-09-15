--- `codex exec --json` (the `ThreadEvent` JSONL stream), as canonical events.
---
--- Shapes captured from codex 0.153/0.154. Codex reports a tool call as an *item* that starts and
--- completes; a completed item is emitted as `tool_start` + `tool_end` when no start was seen, so
--- items that only ever complete (`web_search`) still render.
--- @module vibing.infrastructure.adapter.decoders.codex_exec_json

local TokenUsage = require("vibing.core.utils.token_usage")

local M = {}

local CHANGE_KIND_LABELS = {
  add = "created",
  delete = "deleted",
  update = "modified",
}

--- Extract inner command from codex shell wrapper
--- @param cmd string
--- @return string
function M.extract_inner_command(cmd)
  local inner = cmd:match("^/[^ ]+ %-lc [\"'](.+)[\"']$")
  return inner or cmd
end

--- @param item table
--- @return string[]
local function change_paths(item)
  local paths = {}
  for _, change in ipairs(item.changes or {}) do
    if change.path then
      table.insert(paths, change.path)
    end
  end
  return paths
end

--- @param item table
--- @return string
local function change_summary(item)
  local lines = {}
  for _, change in ipairs(item.changes or {}) do
    local kind_label = CHANGE_KIND_LABELS[change.kind] or change.kind or "changed"
    table.insert(lines, string.format("%s %s", kind_label, change.path or "unknown"))
  end
  return table.concat(lines, "\n")
end

--- @param result any an mcp_tool_call result
--- @return string
local function mcp_result_text(result)
  if type(result) == "table" and result.content then
    local parts = {}
    for _, c in ipairs(result.content) do
      if type(c) == "table" and c.text then
        table.insert(parts, c.text)
      elseif type(c) == "string" then
        table.insert(parts, c)
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

--- The `tool_start` for an item, in codex's own tool names (the vocabulary maps them).
--- @param item table
--- @return Vibing.CanonicalEvent|nil
local function start_event(item)
  if item.type == "command_execution" then
    return {
      kind = "tool_start",
      id = item.id,
      name = item.tool_name or "Bash",
      input = { command = M.extract_inner_command(item.command or "") },
    }
  elseif item.type == "file_change" then
    return { kind = "tool_start", id = item.id, name = "apply_patch", input = { file_paths = change_paths(item) } }
  elseif item.type == "mcp_tool_call" then
    return {
      kind = "tool_start",
      id = item.id,
      name = string.format("mcp__%s__%s", item.server or "", item.tool or ""),
      input = {},
    }
  elseif item.type == "web_search" then
    return { kind = "tool_start", id = item.id, name = "web_search", input = { query = item.query } }
  end
  return nil
end

--- @param item table
--- @return Vibing.CanonicalEvent|nil
local function end_event(item)
  if item.type == "command_execution" then
    return { kind = "tool_end", id = item.id, result = item.aggregated_output or "" }
  elseif item.type == "file_change" then
    return { kind = "tool_end", id = item.id, result = change_summary(item) }
  elseif item.type == "mcp_tool_call" then
    if item.error then
      return { kind = "tool_end", id = item.id, result = tostring(item.error), is_error = true }
    end
    return { kind = "tool_end", id = item.id, result = mcp_result_text(item.result) }
  elseif item.type == "web_search" then
    return { kind = "tool_end", id = item.id, result = "" }
  end
  return nil
end

--- @param err any
--- @return string
local function error_message(err)
  if type(err) == "table" then
    return tostring(err.message or vim.inspect(err))
  end
  return tostring(err)
end

local by_type = {}

by_type["thread.started"] = function(msg, events)
  if msg.thread_id then
    table.insert(events, { kind = "session", session_id = msg.thread_id })
  end
  table.insert(events, { kind = "first_response" })
end

by_type["turn.started"] = function(_, events)
  table.insert(events, { kind = "first_response" })
end

by_type["item.started"] = function(msg, events, state)
  local item = msg.item
  if not item or not item.id then
    return
  end
  local start = start_event(item)
  if start then
    state.started = state.started or {}
    state.started[item.id] = true
    table.insert(events, start)
  end
end

by_type["item.completed"] = function(msg, events, state)
  local item = msg.item
  if not item then
    return
  end
  if item.type == "agent_message" then
    if item.text then
      table.insert(events, { kind = "text", delta = item.text })
    end
    return
  elseif item.type == "reasoning" then
    if item.text and item.text ~= "" then
      table.insert(events, { kind = "thinking", delta = item.text })
    end
    return
  end

  if not item.id then
    return
  end
  state.started = state.started or {}
  if not state.started[item.id] then
    local start = start_event(item)
    if start then
      table.insert(events, start)
    end
  end
  state.started[item.id] = nil
  local finish = end_event(item)
  if finish then
    table.insert(events, finish)
  end
end

--- Codex emits its only token report on the terminal event, cumulative for the thread on a
--- resumed session. `TokenUsage.from_codex` tags it so the reporter treats it as a session total
--- rather than one request.
by_type["turn.completed"] = function(msg, events)
  local accumulator = TokenUsage.from_codex(msg.usage)
  if accumulator then
    table.insert(events, { kind = "usage", accumulator = accumulator })
  end
end

by_type["turn.failed"] = function(msg, events)
  if msg.error then
    table.insert(events, { kind = "error", message = error_message(msg.error) })
  end
end

by_type["error"] = function(msg, events)
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
