--- `opencode acp` Agent Client Protocol JSON-RPC. The shared transport owns processes, turns and
--- timers; this module is only the wire.
--- @module vibing.infrastructure.adapter.modules.opencode_duplex_protocol

local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")

--- The turn, the pool and JSON-RPC correlation are shared with codex's app-server transport; what
--- is below is only what ACP itself decides. `jsonrpc = "2.0"` is required on every ACP frame.
local Rpc = require("vibing.infrastructure.adapter.modules.duplex_jsonrpc").bind({
  processor = require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
    require("vibing.infrastructure.adapter.decoders.opencode_acp"),
    require("vibing.infrastructure.adapter.modules.opencode_tool_vocabulary")
  ),
  agent = "OpenCode agent",
  jsonrpc = true,
})
local fail, render, request = Rpc.fail, Rpc.render, Rpc.request

local M = {}

--- End the turn this reply belongs to.
---
--- **The reply is the correlation.** `session/prompt` answers with the turn's own `stopReason`, and
--- a JSON-RPC response is matched to its request by id — so unlike claude's duplex path there is no
--- question of whose turn ended (`decoders/opencode_acp.lua` deliberately emits no `turn_end`, and
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
  if type(result.usage) == "table" then
    local usage = result.usage
    local input = tonumber(usage.inputTokens) or 0
    local cached = tonumber(usage.cachedReadTokens) or 0
    local TokenUsage = require("vibing.core.utils.token_usage")
    turn.context.tokenUsage = turn.context.tokenUsage or TokenUsage.new()
    TokenUsage.record(turn.context.tokenUsage, {
      input_tokens = math.max(0, input - cached),
      cache_read_input_tokens = cached,
      cache_creation_input_tokens = 0,
    }, false)
  end
  if result.stopReason == "cancelled" then
    turn.complete(TurnOutcome.cancelled(Routing.ids_of(record, turn), content))
  else
    turn.complete(TurnOutcome.ended(Routing.ids_of(record, turn), content, nil))
  end

  -- **A process we cancelled is retired, not reused.** The reply coming back is *not* proof the
  -- session will take another prompt, and the pool's reuse test -- alive, same argv, no open turn
  -- -- says yes exactly when it must not. Retiring costs one respawn on the next message, which is
  -- what cancelling cost before this transport existed; the alternative is a sleep whose length
  -- nothing measured.
  --
  -- Keyed on **whether we sent the cancel**, not on `stopReason`: a rejected approval also ends a
  -- turn as `cancelled`, and that process *is* reusable.
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
  -- Opens `opencode_acp` to session updates. Catch-up from `session/load` is dropped until this.
  render(record, { method = "vibing/promptStarted" })
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
--- @return table session_params
local function session_params(params)
  local mcp = require("vibing.infrastructure.adapter.modules.opencode_mcp_config").resolve(params)
  return { cwd = params.cwd, mcpServers = mcp.servers }
end

--- The values OpenCode's config options should hold for this turn.
---
--- `mode` is one of OpenCode's two session modes (`build` / `plan`), not vibing's permission mode:
--- the other modes are carried by the permission rules in `OPENCODE_CONFIG_CONTENT`.
--- @param opts Vibing.AdapterOpts
--- @return table<string, string|nil>
local function requested_options(opts)
  opts = opts or {}
  return {
    model = type(opts.model) == "string" and opts.model ~= "" and opts.model or nil,
    mode = opts.permission_mode == "plan" and "plan" or "build",
    effort = type(opts.effort) == "string" and opts.effort ~= "" and opts.effort or "default",
  }
end

--- Remember what the session last accepted, from a `session/new`, `session/load` or
--- `session/set_config_option` reply. The reply carries the whole `configOptions` list.
--- @param record Vibing.DuplexProcess
--- @param result table
local function record_applied(record, result)
  local applied = record._rpc.applied or {}
  for _, option in ipairs(result.configOptions or {}) do
    if type(option) == "table" and option.id then
      applied[option.id] = option.currentValue
    end
  end
  record._rpc.applied = applied
end

--- Apply the requested options one at a time, then send the prompt.
---
--- OpenCode applies a config option asynchronously; a prompt written in the same tick can reach the
--- session before the option does. On a reused session the options also start at whatever the
--- previous turn left behind, so a changed model, mode or effort has to be sent here rather than
--- only in the `session/new` callback.
--- @param record Vibing.DuplexProcess
--- @param opts Vibing.AdapterOpts
--- @param next_fn fun()
local function apply_options(record, opts, next_fn)
  local rpc = record._rpc
  rpc.applied = rpc.applied or {}
  local desired = requested_options(opts)
  local steps = {}
  for _, id in ipairs({ "model", "mode", "effort" }) do
    local want = desired[id]
    if want ~= nil and want ~= rpc.applied[id] then
      table.insert(steps, function(next)
        if
          not request(record, "session/set_config_option", {
            sessionId = rpc.session_id,
            configId = id,
            value = want,
          }, function(result)
            record_applied(record, result)
            next()
          end)
        then
          return
        end
      end)
    end
  end

  local function run(index)
    local step = steps[index]
    if not step then
      next_fn()
      return
    end
    step(function()
      run(index + 1)
    end)
  end
  run(1)
end

--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @param params Vibing.DuplexRunParams
--- @return boolean sent
function M.send_prompt(record, prompt, params)
  if record._rpc and record._rpc.session_id then
    apply_options(record, params.opts, function()
      send_prompt_now(record, prompt)
    end)
    return true
  end
  record._rpc = { seq = 0, pending = {} }

  -- Exactly the two fields this transport sends. A `clientInfo` block is **not** added: nothing
  -- measured it here, and a stubbed spec cannot see the difference, since the stub answers
  -- whatever it is sent.
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
      -- `session/load` answers with no `sessionId` of its own; the one we asked to resume is the
      -- session, so a missing field is not a failure there.
      local id = result.sessionId or session
      if type(id) ~= "string" then
        fail(record, "OpenCode " .. method .. " returned no session id.")
        return
      end
      record._rpc.session_id = id
      record_applied(record, result)
      -- The id arrives in a reply, never in a notification, so the decoder is handed one.
      render(record, { method = "vibing/sessionStarted", params = { session_id = id } })

      apply_options(record, params.opts, function()
        send_prompt_now(record, prompt)
      end)
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
  -- A reply to something we asked. The id correlates it; `method` being absent is what makes it a
  -- response rather than a request of the agent's own.
  if msg.id ~= nil and not msg.method then
    Rpc.reply(record, msg)
    return
  end

  if msg.id ~= nil then
    -- A permission request needs `result.outcome`; the generic unsupported-method error carries no
    -- decision, so the call would be left unresolved. This declines the call and never approves
    -- one — approval belongs to the OpenCode plugin bridge, not to the transport.
    if msg.method == "session/request_permission" then
      local params = msg.params or {}
      local reject
      for _, option in ipairs(params.options or {}) do
        if option.kind == "reject_once" then
          reject = option.optionId
          break
        end
      end
      local outcome = reject and { outcome = "selected", optionId = reject } or { outcome = "cancelled" }
      if not Process.write(record, { jsonrpc = "2.0", id = msg.id, result = { outcome = outcome } }) then
        fail(record, "Could not answer an OpenCode permission request.")
        return
      end
      render(record, {
        method = "vibing/requestDenied",
        params = {
          message = "OpenCode asked for permission to run "
            .. ((params.toolCall or {}).title or "a tool call")
            .. "; vibing.nvim refused it in duplex mode.",
        },
      })
      return
    end
    if
      not Process.write(record, {
        jsonrpc = "2.0",
        id = msg.id,
        error = { code = -32601, message = "Unsupported OpenCode request: " .. tostring(msg.method) },
      })
    then
      fail(record, "Could not answer an OpenCode agent request.")
      return
    end
    render(record, {
      method = "vibing/requestDenied",
      params = {
        message = "OpenCode requested " .. tostring(msg.method) .. "; this request is not supported in duplex mode.",
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
function M.interrupt(record, _seq)
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
