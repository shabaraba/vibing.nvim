--- Pi JSONL RPC, based on the upstream RPC reference and rpc-types.ts (Pi 1.2.0).
--- https://pi.dev/docs/latest/rpc
--- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts
--- Prompt replies acknowledge acceptance;
--- agent_settled ends the run after tools, retries and compaction have finished.
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local Processor = require("vibing.infrastructure.adapter.modules.pi_event_processor")
local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
local Outcome = require("vibing.infrastructure.adapter.modules.turn_outcome")
local M = {}

local function context(record)
  return record._turn and record._turn.context or record._idle_context
end

local function render(record, msg)
  local ctx = context(record)
  if ctx then
    Processor.apply(msg, ctx)
  end
end

local function fail(record, message)
  local turn = record._turn
  if turn then
    turn.complete(Outcome.ended(Routing.ids_of(record, turn), table.concat(turn.context.output, ""), message))
  end
  local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
  local key, current = Pool.find_by_process_id(record.process_id)
  if current == record then
    Pool.stop(key, "unresponsive")
  end
end

local function request(record, command, fields, callback)
  local rpc = record._pi_rpc
  rpc.seq = rpc.seq + 1
  local id = "vibing-pi-" .. rpc.seq
  rpc.pending[id] = { command = command, callback = callback, turn = record._turn }
  if not Process.write(record, vim.tbl_extend("force", { id = id, type = command }, fields or {})) then
    rpc.pending[id] = nil
    fail(record, "Could not write " .. command .. " to Pi.")
    return false
  end
  return true
end

function M.send_prompt(record, prompt, _params)
  record._pi_rpc = record._pi_rpc or { seq = 0, pending = {} }
  local rpc = record._pi_rpc
  rpc.interrupted = false
  rpc.active = false
  rpc.aborted = false
  -- These announcements belong to each response, not to the lifetime of the process.
  record.decoder_state.announced_first_response = nil
  record.decoder_state.announced_model = nil
  record.decoder_state.terminal_error = nil
  local turn = record._turn
  local function send()
    if record._turn ~= turn then
      return
    end
    if rpc.interrupted then
      turn.complete(Outcome.cancelled(Routing.ids_of(record, turn), ""))
      return
    end
    request(record, "prompt", { message = prompt }, function(reply)
      if record._turn ~= turn then
        return
      end
      local disposition = type(reply.data) == "table" and reply.data.disposition
      if disposition == "handled" then
        turn.context.onTurnEnd()
      elseif disposition and disposition ~= "started" then
        fail(record, "Pi did not start this prompt: " .. tostring(disposition))
      else
        rpc.active = true
      end
    end)
  end
  if rpc.session_id then
    send()
    return true
  end
  return request(record, "get_state", {}, function(reply)
    local data = type(reply.data) == "table" and reply.data or {}
    if type(data.sessionId) ~= "string" or data.sessionId == "" then
      fail(record, "Pi get_state returned no session id.")
      return
    end
    rpc.session_id = data.sessionId
    render(record, { type = "session", id = data.sessionId })
    send()
  end)
end

function M.process_line(record, line)
  local ok, msg = pcall(vim.json.decode, line)
  local rpc = record._pi_rpc
  if not ok or type(msg) ~= "table" or not rpc then
    return false
  end
  if msg.type == "response" then
    local pending = rpc.pending[msg.id]
    if not pending or msg.command ~= pending.command then
      return false
    end
    rpc.pending[msg.id] = nil
    if record._turn ~= pending.turn then
      return true
    end
    if msg.success ~= true then
      fail(record, "Pi " .. pending.command .. ": " .. tostring(msg.error or "command failed"))
    elseif pending.callback then
      pending.callback(msg)
    end
    return true
  end
  if msg.type == "extension_ui_request" then
    if vim.tbl_contains({ "select", "confirm", "input", "editor" }, msg.method) and type(msg.id) == "string" then
      if not Process.write(record, { type = "extension_ui_response", id = msg.id, cancelled = true }) then
        fail(record, "Could not decline an unsupported Pi extension dialog.")
      else
        render(record, { type = "message_update", assistantMessageEvent = {
          type = "error", error = "Pi extension dialog is not supported: " .. msg.method,
        } })
      end
    end
    return true
  end
  -- Events have no command id. Only a run started by our accepted prompt can end
  -- our turn. We never queue steering/follow-up prompts or feed extension events.
  if not rpc.active then
    return false
  end
  if msg.type == "message_end" and type(msg.message) == "table" and msg.message.role == "assistant" then
    local message = msg.message
    rpc.aborted = message.stopReason == "aborted"
  end
  if msg.type == "agent_settled" then
    rpc.active = false
    local turn = record._turn
    if turn and (rpc.interrupted or rpc.aborted) then
      turn.complete(Outcome.cancelled(Routing.ids_of(record, turn), table.concat(turn.context.output, "")))
    else
      render(record, msg)
    end
    return true
  end
  return Processor.apply(msg, context(record))
end

function M.interrupt(record, _seq)
  local rpc = record._pi_rpc
  if not rpc then
    return false
  end
  rpc.interrupted = true
  return request(record, "abort", {})
end

return M
