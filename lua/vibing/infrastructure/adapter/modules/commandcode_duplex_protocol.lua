--- `commandcode acp` — Agent Client Protocol JSON-RPC over stdio. The shared transport owns
--- processes, turns and timers; this module is only the wire.
--- @module vibing.infrastructure.adapter.modules.commandcode_duplex_protocol

local NativeApproval = require("vibing.infrastructure.adapter.modules.commandcode_native_approval")
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")

--- The turn, the pool and JSON-RPC correlation are shared with codex's and grok's transports; what
--- is below is only what ACP itself decides. `jsonrpc = "2.0"` is required on every frame.
local Rpc = require("vibing.infrastructure.adapter.modules.duplex_jsonrpc").bind({
  processor = require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
    require("vibing.infrastructure.adapter.decoders.commandcode_acp"),
    require("vibing.infrastructure.adapter.modules.commandcode_tool_vocabulary")
  ),
  agent = "Command Code agent",
  jsonrpc = true,
})
local fail, render, request = Rpc.fail, Rpc.render, Rpc.request

local M = {}

--- End the turn this reply belongs to.
---
--- **The reply is the correlation.** `session/prompt` answers with the turn's own `stopReason`, and
--- a JSON-RPC response is matched to its request by id — so unlike claude's duplex path there is no
--- question of whose turn ended, and `duplex_turn.ends_this_turn` is never consulted here (the
--- decoder emits no `turn_end` for it to gate on).
--- @param record Vibing.DuplexProcess
--- @param result table
local function finish_turn(record, result)
  local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
  local turn = Routing.turn_of(record)
  if not turn then
    return
  end
  local content = table.concat(turn.context.output, "")

  if type(result.usage) == "table" then
    local usage = result.usage
    local TokenUsage = require("vibing.core.utils.token_usage")
    local cached = tonumber(usage.cachedReadTokens) or 0
    turn.context.tokenUsage = turn.context.tokenUsage or TokenUsage.new()
    TokenUsage.record(turn.context.tokenUsage, {
      -- `inputTokens` includes the cached read (measured: `totalTokens == inputTokens +
      -- outputTokens`), so the cached share is subtracted the way the one records do.
      input_tokens = math.max(0, (tonumber(usage.inputTokens) or 0) - cached),
      cache_read_input_tokens = cached,
      cache_creation_input_tokens = tonumber(usage.cachedWriteTokens) or 0,
    }, false)
  end

  if result.stopReason == "cancelled" then
    turn.complete(TurnOutcome.cancelled(Routing.ids_of(record, turn), content))
    -- **A process we cancelled is retired, not reused.** The reply coming back is not proof the
    -- session will take another prompt, and the pool's reuse test (alive, same argv, no open turn)
    -- says yes exactly when it must not. Retiring costs one respawn on the next message.
    local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
    local key, current = Pool.find_by_process_id(record.process_id)
    if current == record then
      Pool.stop(key, "cancelled")
    end
    return
  end

  turn.complete(TurnOutcome.ended(Routing.ids_of(record, turn), content, nil))
end

--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @return boolean sent
local function send_prompt_now(record, prompt)
  -- Opens `commandcode_acp` to session updates. Catch-up from `session/load` is dropped until this.
  render(record, { method = "vibing/promptStarted" })
  return request(record, "session/prompt", {
    sessionId = record._rpc.session_id,
    prompt = { { type = "text", text = prompt } },
  }, function(result)
    finish_turn(record, result)
  end)
end

--- The vibing permission mode as one of Command Code's ACP mode ids, or nil to leave it alone.
---
--- `default` and `acceptEdits` map to nothing: Command Code's own headless gate is all-or-nothing
--- (`--yolo` or "refuse writes"), so there is no mode to request — the oneshot path's
--- `permission_args` says the same thing about the flag side. Only the two modes that ask for
--- something *more* than the default are sent.
--- @param mode string|nil
--- @return string|nil
local function acp_mode(mode)
  if mode == "plan" then
    return "plan"
  end
  if mode == "dontAsk" then
    return "dont-ask"
  end
  if mode == "auto" then
    return "auto-accept"
  end
  return nil
end

--- The model a `session/new` / `session/load` reply says is already configured, if it says.
---
--- The reply carries `configOptions` — the same list `session/set_config_option` answers with —
--- so the option only has to be set when it would change something.
--- @param result table
--- @return string|nil
local function current_model(result)
  for _, option in ipairs(result.configOptions or {}) do
    if type(option) == "table" and option.id == "model" then
      return option.currentValue
    end
  end
  return nil
end

--- @param params Vibing.DuplexRunParams
--- @return table session_params
local function session_params(params)
  -- `mcpServers` is required by `session/new` — omitting it is an `Invalid params` error naming the
  -- field, not a default — so an empty list is passed. vibing's own MCP server is not injected for
  -- this backend yet.
  return { cwd = params.cwd, mcpServers = {} }
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
  }, function()
    local session = params.opts._session_id
    local method = session and "session/load" or "session/new"
    local new_params = session_params(params)
    if session then
      new_params.sessionId = session
    end
    request(record, method, new_params, function(result)
      -- `session/load` answers with no `sessionId` of its own on some agents; the one we asked to
      -- resume is the session, so a missing field is not a failure there.
      local id = result.sessionId or session
      if type(id) ~= "string" then
        fail(record, "Command Code " .. method .. " returned no session id.")
        return
      end
      record._rpc.session_id = id
      -- The id arrives in a reply, never in a notification, so the decoder is handed one.
      render(record, { method = "vibing/sessionStarted", params = { session_id = id } })

      -- Model and mode via ACP, **each awaited before the next is written**.
      --
      -- Command Code handles `session/set_config_option` asynchronously: a `session/prompt` written
      -- in the same tick reaches the agent while the option call is still in flight, the prompt
      -- marks the session busy, and *both* calls then come back with "A prompt is already running
      -- for this session" (measured on 1.88.2 — the calls are chained rather than fired together
      -- for exactly this reason). An unsupported option would fail the turn through `Rpc.reply`,
      -- so nothing speculative (an effort option, say) is sent here.
      local opts = params.opts or {}
      local model = type(opts.model) == "string" and opts.model ~= "" and opts.model or nil
      local steps = {}

      -- `session/new` answers with the running `configOptions` already, so the model is only set
      -- when it differs — one fewer round trip, and one fewer chance to race.
      if model and model ~= current_model(result) then
        table.insert(steps, function(next)
          request(record, "session/set_config_option", { sessionId = id, configId = "model", value = model }, next)
        end)
      end
      local mode = acp_mode(opts.permission_mode)
      if mode then
        table.insert(steps, function(next)
          request(record, "session/set_mode", { sessionId = id, modeId = mode }, next)
        end)
      end

      local function run(index)
        local step = steps[index]
        if not step then
          send_prompt_now(record, prompt)
          return
        end
        step(function()
          run(index + 1)
        end)
      end
      run(1)
    end)
  end)
end

--- One decoded line from the resident agent.
---
--- Takes **no context**: a handshake failure, a deferred `session/new` reply and a locally-built
--- notice are none of them synchronous with a line, so the turn a message belongs to is resolved in
--- `render` instead of being captured here.
--- @param record Vibing.DuplexProcess
--- @param line string
function M.process_line(record, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" or not record._rpc then
    return
  end
  -- A reply to something we asked: the id correlates it, and `method` being absent is what makes it
  -- a response rather than a request of the agent's own.
  if msg.id ~= nil and not msg.method then
    Rpc.reply(record, msg)
    return
  end

  if msg.id ~= nil then
    -- Command Code's own permission engine runs *before* the mod bridge and, for a call it would
    -- gate, asks the client over ACP instead of deciding. Unanswered (or answered with an error)
    -- the call fails as "Permission denied by the user." and the turn ends, so this request is the
    -- one the client must handle — see `commandcode_native_approval.lua`.
    if NativeApproval.handles(msg.method) then
      local answered, notice = NativeApproval.handle(record, msg)
      if not answered then
        fail(record, "Could not answer a Command Code permission request.")
      elseif notice then
        render(record, { method = "vibing/requestDenied", params = { message = notice } })
      end
      return
    end
    if
      not Process.write(record, {
        jsonrpc = "2.0",
        id = msg.id,
        error = { code = -32601, message = "Unsupported Command Code request: " .. tostring(msg.method) },
      })
    then
      fail(record, "Could not answer a Command Code agent request.")
      return
    end
    render(record, {
      method = "vibing/requestDenied",
      params = {
        message = "Command Code requested " .. tostring(msg.method) .. "; this request is not supported in duplex mode.",
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
--- agent answers with `stopReason = "cancelled"`.
--- @param record Vibing.DuplexProcess
--- @return boolean sent
function M.interrupt(record, _seq)
  local rpc = record._rpc
  if not rpc or not rpc.session_id then
    return false
  end
  return Process.write(record, {
    jsonrpc = "2.0",
    method = "session/cancel",
    params = { sessionId = rpc.session_id },
  })
end

return M
