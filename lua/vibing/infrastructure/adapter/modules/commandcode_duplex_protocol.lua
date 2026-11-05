--- `commandcode acp` — Agent Client Protocol JSON-RPC over stdio. The shared transport owns
--- processes, turns and timers; this module is only the wire.
--- @module vibing.infrastructure.adapter.modules.commandcode_duplex_protocol

local CommandBuilder = require("vibing.infrastructure.adapter.modules.commandcode_command_builder")
local McpConfig = require("vibing.infrastructure.adapter.modules.commandcode_mcp_config")
local NativeApproval = require("vibing.infrastructure.adapter.modules.commandcode_native_approval")
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local ReasoningEffort = require("vibing.infrastructure.adapter.modules.reasoning_effort")
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

--- The option a session reply reported for one config id, if it reported one.
---
--- `session/new` / `session/load` and every `session/set_config_option` reply carry the same
--- `configOptions` list, so the current value of any option is readable from any of them.
--- @param result table
--- @param id string
--- @return table|nil
local function config_option(result, id)
  for _, option in ipairs((result or {}).configOptions or {}) do
    if type(option) == "table" and option.id == id then
      return option
    end
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
  local option = config_option(result, "model")
  return option and option.currentValue or nil
end

--- What the session last said about its effort option: the value in force, and the levels the
--- current model offers.
---
--- Cached from **every** reply the pipeline awaits, because both halves move where the *model*
--- request answers: the offered set is model-dependent (measured on 1.88.2 — a Claude model offers
--- default/low/medium/high/xhigh/max, DeepSeek V4 Flash off/high/max, and a Claude set's `low` is
--- rejected there outright), and switching models resets the value to `default`. That reset is why
--- the model step's callback runs this too, and why the effort step re-reads the cache rather
--- than deciding once up front.
---
--- The offered levels are reduced to bare strings here: the CLI reports each as
--- `{ value = "...", name = "..." }`, and both the membership test and the warning want the
--- values.
--- @param rpc table
--- @param result table
local function note_effort(rpc, result)
  local option = config_option(result, "effort")
  if not option then
    return
  end
  rpc.effort_offered = vim.tbl_map(function(entry)
    return entry.value
  end, option.options or {})
  rpc.applied_effort = option.currentValue
end

--- The mode a `session/new` / `session/load` reply says is already active, if it says.
--- @param result table
--- @return string|nil
local function current_mode(result)
  local modes = result.modes
  return type(modes) == "table" and modes.currentModeId or nil
end

--- The step that hands the chat's effort to the session.
---
--- Compared and validated *inside* the step, because the model step ahead of it moves both facts
--- this spelling depends on — a model switch resets the session's effort to `default` and swaps
--- the offered set, in its own reply (measured on 1.88.2).
---
--- The offered set is the session's own answer and is model-dependent (a Claude model offers
--- default/low/medium/high/xhigh/max, DeepSeek V4 Flash off/high/max), so a level vibing accepts
--- but this model does not is skipped with a warning rather than sent, where the CLI's
--- `Unknown effort` error would fail the turn. A session that never reported the option has none
--- to set.
--- @param record Vibing.DuplexProcess
--- @param rpc table
--- @param effort string
--- @return fun(next: fun())
local function effort_step(record, rpc, effort)
  return function(next)
    if effort == rpc.applied_effort then
      next()
      return
    end
    local offered = rpc.effort_offered or {}
    if #offered == 0 or not vim.tbl_contains(offered, effort) then
      require("vibing.core.utils.notify").warn(string.format(
        "Ignoring effort %s: this session offers %s",
        effort,
        #offered > 0 and table.concat(offered, ", ") or "no effort levels"
      ))
      next()
      return
    end
    if
      not request(record, "session/set_config_option", {
        sessionId = rpc.session_id,
        configId = "effort",
        value = effort,
      }, function(reply)
        note_effort(rpc, reply)
        -- Trusted over the request the way the model step is; a reply without the option would
        -- otherwise re-send the same value on every turn.
        rpc.applied_effort = rpc.applied_effort or effort
        next()
      end)
    then
      return
    end
  end
end

--- Apply a changed model, mode or effort to the session, then send the prompt.
---
--- A resident process keeps the configuration it was spawned with, and `session/new` is where this
--- backend applied the previous turn's model and mode. Comparing against what the session last
--- reported means a change between turns is sent before the prompt instead of being silently
--- ignored. Each request is awaited: Command Code handles `session/set_config_option`
--- asynchronously, and writing the prompt in the same tick makes both calls fail with "A prompt is
--- already running for this session" (measured on 1.88.2).
---
--- Effort rides the same `session/set_config_option` route after the model (see `effort_step`);
--- a chat's `default` resolves to nil and so sends nothing, which leaves a session that already
--- had an explicit effort on it — once one has been set the CLI drops `default` from the offered
--- set and rejects it back (`Unknown effort: default`, measured on 1.88.2).
--- @param record Vibing.DuplexProcess
--- @param params Vibing.DuplexRunParams
--- @param result table|nil the `session/new` / `session/load` reply, when there is one
--- @param next_fn fun()
local function apply_options(record, params, result, next_fn)
  local opts = params.opts or {}
  local rpc = record._rpc
  if result then
    rpc.applied_model = current_model(result)
    rpc.applied_mode = current_mode(result)
  end
  note_effort(rpc, result)

  local model = type(opts.model) == "string" and opts.model ~= "" and opts.model or nil
  local mode = acp_mode(opts.permission_mode) or "default"
  local steps = {}

  if model and model ~= rpc.applied_model then
    table.insert(steps, function(next)
      if
        not request(record, "session/set_config_option", {
          sessionId = rpc.session_id,
          configId = "model",
          value = model,
        }, function(reply)
          -- The effort cache too: this reply is the one that reports the model switch's effort
          -- reset, so the effort step behind it decides on the post-switch value.
          note_effort(rpc, reply)
          rpc.applied_model = current_model(reply) or model
          next()
        end)
      then
        return
      end
    end)
  end
  if mode ~= rpc.applied_mode then
    table.insert(steps, function(next)
      if
        not request(record, "session/set_mode", {
          sessionId = rpc.session_id,
          modeId = mode,
        }, function()
          rpc.applied_mode = mode
          next()
        end)
      then
        return
      end
    end)
  end
  local effort = ReasoningEffort.resolve(opts, params.config)
  if effort then
    table.insert(steps, effort_step(record, rpc, effort))
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

--- @param params Vibing.DuplexRunParams
--- @return table session_params
--- @return string|nil self_server the bundled server's registered name, for the instructions
local function session_params(params)
  -- `mcpServers` is required by `session/new` — omitting it is an `Invalid params` error naming the
  -- field, not a default — so the list is always present, empty on a lightweight call. Command Code
  -- has no `--plugin-dir`, so this is the only route by which the bundled `vibing-nvim` server (and
  -- each plugin's `mcpServers`) reaches the CLI: it connects what the client sends.
  local mcp = McpConfig.resolve(params)
  return { cwd = params.cwd, mcpServers = mcp.servers }, mcp.self_server
end

--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @param params Vibing.DuplexRunParams
--- @return boolean sent
function M.send_prompt(record, prompt, params)
  -- The bridge is the real gate, so `commandcode_native_approval` may answer `allow_once` only
  -- when this turn actually installed it. Set every turn: a later turn whose hook install failed
  -- must not inherit the previous turn's answer.
  local hook_installed = params.hook_arg ~= nil
  if record._rpc and record._rpc.session_id then
    record._rpc.hook_installed = hook_installed
    apply_options(record, params, nil, function()
      send_prompt_now(record, prompt)
    end)
    return true
  end
  record._rpc = { seq = 0, pending = {}, hook_installed = hook_installed }

  return request(record, "initialize", {
    protocolVersion = 1,
    clientCapabilities = vim.empty_dict(),
  }, function()
    local session = params.opts._session_id
    local method = session and "session/load" or "session/new"
    local new_params, self_server = session_params(params)
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

      apply_options(record, params, result, function()
        send_prompt_now(record, CommandBuilder.with_instructions(prompt, self_server ~= nil))
      end)
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
