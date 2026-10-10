--- `grok agent stdio` Agent Client Protocol JSON-RPC. The shared transport owns processes, turns
--- and timers; this module is only the wire.
--- @module vibing.infrastructure.adapter.modules.grok_duplex_protocol

local NativeApproval = require("vibing.infrastructure.adapter.modules.grok_native_approval")
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")
local Processor = require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.grok_acp"),
  require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")
)

local M = {}

--- @param record Vibing.DuplexProcess
--- @param message string
local function fail(record, message)
  local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
  local turn = Routing.turn_of(record)
  if turn then
    turn.complete(
      TurnOutcome.ended(Routing.ids_of(record, turn), table.concat(turn.context.output, ""), message)
    )
  end
  local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
  local key, current = Pool.find_by_process_id(record.process_id)
  if current == record then
    Pool.stop(key, "unresponsive")
  end
end

--- Resolve the turn when rendering rather than when the line arrived, for the reason
--- `M.process_line` states: most of what this module renders comes out of a deferred callback.
--- @param record Vibing.DuplexProcess
--- @param msg table
local function render(record, msg)
  local turn = record._turn
  local context = turn and turn.context or record._idle_context
  if context then
    Processor.apply(msg, context)
  end
end

--- @param record Vibing.DuplexProcess
--- @param method string
--- @param params table
--- @param callback fun(result: table)
--- @return boolean sent
local function request(record, method, params, callback)
  local rpc = record._rpc
  rpc.seq = rpc.seq + 1
  local id = "vibing-rpc-" .. rpc.seq
  rpc.pending[id] = callback
  if not Process.write(record, { jsonrpc = "2.0", id = id, method = method, params = params }) then
    rpc.pending[id] = nil
    fail(record, "Could not write " .. method .. " to the Grok agent.")
    return false
  end
  return true
end

--- End the turn this reply belongs to.
---
--- **The reply is the correlation.** `session/prompt` answers with the turn's own `stopReason`, and
--- a JSON-RPC response is matched to its request by id — so unlike claude's duplex path there is no
--- question of whose turn ended (`decoders/grok_acp.lua` deliberately emits no `turn_end`, and
--- `duplex_turn.ends_this_turn` is never consulted here).
--- @param record Vibing.DuplexProcess
--- @param result table
local function finish_turn(record, result)
  local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
  local turn = Routing.turn_of(record)
  if not turn then
    return
  end
  local content = table.concat(turn.context.output, "")
  local interrupted = record._rpc.interrupted
  if result.stopReason == "cancelled" then
    turn.complete(TurnOutcome.cancelled(Routing.ids_of(record, turn), content))
  else
    turn.complete(TurnOutcome.ended(Routing.ids_of(record, turn), content, nil))
  end

  -- **A process we cancelled is retired, not reused.** Measured against grok 1.0.50: after a
  -- `session/cancel` the agent answers the in-flight prompt in ~2ms, but a `session/prompt` sent
  -- 16ms later never gets a reply at all (65s, to the probe's own deadline), while one sent 8s
  -- later completes normally. So the reply coming back is *not* proof the session will take
  -- another prompt, and the pool's reuse test -- alive, same argv, no open turn -- says yes exactly
  -- when it must not. Retiring costs one respawn on the next message, which is what cancelling
  -- cost before this transport existed; the alternative is a sleep whose length nothing measured.
  --
  -- Keyed on **whether we sent the cancel**, not on `stopReason`: a rejected approval also ends a
  -- turn as `cancelled`, and that process *is* reusable -- three prompts in a row over one
  -- rejection are what the approval probe recorded.
  if interrupted then
    local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
    local key, current = Pool.find_by_process_id(record.process_id)
    if current == record then
      Pool.stop(key, "cancelled")
    end
  end
end

--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @return boolean sent
local function send_prompt_now(record, prompt)
  local rpc = record._rpc
  rpc.interrupted = false
  return request(record, "session/prompt", {
    sessionId = rpc.session_id,
    prompt = { { type = "text", text = prompt } },
  }, function(result)
    finish_turn(record, result)
  end)
end

--- `session/new` and `session/load` take the same params; the resumed one also names the session.
--- `mcpServers` is **required on both** -- omitting it is an `Invalid params` error naming the
--- field, not a default -- so an empty list is passed rather than nothing.
--- @param params Vibing.DuplexRunParams
--- @return table
local function session_params(params)
  return {
    cwd = params.cwd,
    mcpServers = require("vibing.infrastructure.adapter.modules.grok_mcp_config").servers(params),
  }
end

--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @param params Vibing.DuplexRunParams
--- @return boolean sent
function M.send_prompt(record, prompt, params)
  if record._rpc and record._rpc.session_id then
    return send_prompt_now(record, prompt)
  end
  record._rpc = { seq = 0, pending = {} }

  return request(record, "initialize", {
    protocolVersion = 1,
    clientCapabilities = vim.empty_dict(),
    clientInfo = { name = "vibing_nvim", title = "vibing.nvim" },
  }, function()
    local session = params.opts._session_id
    local method = session and "session/load" or "session/new"
    local new_params = session_params(params)
    if session then
      new_params.sessionId = session
    end
    request(record, method, new_params, function(result)
      -- `session/load` answers with no `sessionId` of its own; the one we asked to resume is the
      -- session, so a missing field is not a failure there.
      local id = result.sessionId or session
      if type(id) ~= "string" then
        fail(record, "Grok " .. method .. " returned no session id.")
        return
      end
      record._rpc.session_id = id
      -- The id arrives in a reply, never in a notification, so the decoder is handed one.
      render(record, { method = "vibing/sessionStarted", params = { session_id = id } })

      -- What the one-shot transport puts behind `--rules`. `grok agent` has no such flag, so it
      -- rides on the first prompt of the session and on no later one -- a block repeated every turn
      -- would churn the prompt cache for a system prompt's worth of text that has not changed.
      local rules =
        require("vibing.infrastructure.adapter.modules.grok_command_builder").rules_text(params.opts, params.config)
      send_prompt_now(record, rules and (rules .. "\n\n" .. prompt) or prompt)
    end)
  end)
end

--- One decoded line from the resident agent.
---
--- Takes **no context**: a handshake failure, a deferred `session/new` reply and a locally-built
--- notice are none of them synchronous with a line, so the turn a message belongs to is resolved
--- in `render` instead of being captured here.
--- @param record Vibing.DuplexProcess
--- @param line string
function M.process_line(record, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" or not record._rpc then
    return
  end
  local rpc = record._rpc

  if msg.id ~= nil and not msg.method then
    local callback = rpc.pending[msg.id]
    rpc.pending[msg.id] = nil
    if callback then
      if msg.error then
        fail(record, "Grok agent: " .. tostring(msg.error.message or vim.inspect(msg.error)))
      else
        callback(msg.result or {})
      end
    end
    return
  end

  if msg.id ~= nil then
    if NativeApproval.handles(msg.method) then
      local answered, notice = NativeApproval.handle(record, msg)
      if not answered then
        fail(record, "Could not answer a Grok permission request.")
      elseif notice then
        render(record, { method = "vibing/requestDenied", params = { message = notice } })
      end
      return
    end
    if
      not Process.write(record, {
        jsonrpc = "2.0",
        id = msg.id,
        error = { code = -32601, message = "Unsupported Grok request: " .. tostring(msg.method) },
      })
    then
      fail(record, "Could not answer a Grok agent request.")
      return
    end
    render(record, {
      method = "vibing/requestDenied",
      params = {
        message = "Grok requested " .. tostring(msg.method) .. "; this request is not supported in duplex mode.",
      },
    })
    return
  end

  if msg.method then
    render(record, msg)
  end
end

--- Ask the agent to stop the turn it is running.
---
--- A notification, so nothing is awaited: the turn ends on the `session/prompt` reply, which the
--- agent answers with `stopReason = "cancelled"` within milliseconds.
--- @param record Vibing.DuplexProcess
--- @return boolean sent
function M.interrupt(record)
  local rpc = record._rpc
  if not rpc or not rpc.session_id then
    return false
  end
  -- Set before the write, because `finish_turn` reads it and the reply can arrive first.
  rpc.interrupted = true
  return Process.write(record, {
    jsonrpc = "2.0",
    method = "session/cancel",
    params = { sessionId = rpc.session_id },
  })
end

return M
