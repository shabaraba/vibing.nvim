--- Codex app-server JSON-RPC. The shared transport owns processes, turns and timers.
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local Processor = require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.codex_app_server"),
  require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
)
local M = {}

local function fail(record, message)
  local turn = record._turn
  if turn then
    turn.complete(
      require("vibing.infrastructure.adapter.modules.turn_outcome").ended(
        { turn_id = turn.turn_id, process_id = record.process_id },
        table.concat(turn.context.output, ""),
        message
      )
    )
  end
  local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
  local key, current = Pool.find_by_process_id(record.process_id)
  if current == record then
    Pool.stop(key, "unresponsive")
  end
end

local function request(record, method, params, callback)
  local rpc = record._rpc
  rpc.seq = rpc.seq + 1
  local id = "vibing-rpc-" .. rpc.seq
  rpc.pending[id] = callback
  if not Process.write(record, { id = id, method = method, params = params }) then
    rpc.pending[id] = nil
    fail(record, "Could not write " .. method .. " to the Codex app-server.")
    return false
  end
  return true
end

local function render(record, msg)
  local turn = record._turn
  local context = turn and turn.context or record._idle_context
  if context then
    Processor.processLine(vim.json.encode(msg), context)
  end
end

local function notification(record, msg)
  -- The owned session comes from thread/start or thread/resume's correlated reply.
  -- Child threads may also announce themselves on this connection.
  if msg.method == "thread/started" then
    return
  end
  local p, rpc = msg.params or {}, record._rpc
  if p.threadId and p.threadId ~= rpc.thread_id then
    return
  end
  local id = p.turnId or (p.turn and p.turn.id)
  if id then
    if rpc.starting_turn then
      table.insert(rpc.queued, msg)
      return
    end
    if not record._turn or id ~= rpc.turn_id then
      return
    end
  end
  render(record, msg)
end

local function start_turn(record, prompt, params)
  local rpc = record._rpc
  rpc.starting_turn, rpc.queued = true, {}
  return request(record, "turn/start", {
    threadId = rpc.thread_id,
    model = require("vibing.infrastructure.adapter.modules.non_claude_model").resolve(params.opts, params.config),
    effort = require("vibing.infrastructure.adapter.modules.reasoning_effort").resolve(params.opts, params.config),
    input = { { type = "text", text = prompt } },
  }, function(result)
    if type(result.turn) ~= "table" or not result.turn.id then
      fail(record, "Codex turn/start returned no turn id.")
      return
    end
    rpc.turn_id, rpc.starting_turn = result.turn.id, false
    record.decoder_state.started, record.decoder_state.text_items = nil, nil
    local queued = rpc.queued
    rpc.queued = {}
    for _, msg in ipairs(queued) do
      notification(record, msg)
    end
  end)
end

function M.send_prompt(record, prompt, params)
  if record._rpc then
    return start_turn(record, prompt, params)
  end
  record._rpc = { seq = 0, pending = {}, queued = {} }
  return request(record, "initialize", {
    clientInfo = { name = "vibing_nvim", title = "vibing.nvim", version = "5.9.0" },
  }, function()
    if not Process.write(record, { method = "initialized" }) then
      fail(record, "Could not initialize the Codex app-server.")
      return
    end
    local function start_thread()
      local session = params.opts._session_id
      request(
        record,
        session and "thread/resume" or "thread/start",
        { threadId = session, cwd = params.cwd },
        function(result)
          local thread = result.thread
          if type(thread) ~= "table" or not thread.id then
            fail(record, "Codex returned no thread id.")
            return
          end
          record._rpc.thread_id = thread.id
          render(record, { method = "thread/started", params = { thread = thread } })
          start_turn(record, prompt, params)
        end
      )
    end
    local function check_hook(hooks, after_write)
      local script = require("vibing.infrastructure.hooks.codex_settings_generator").script_path(params.cwd)
      local target
      for _, group in ipairs(hooks.data or {}) do
        for _, hook in ipairs(group.hooks or {}) do
          if
            hook.eventName == "preToolUse"
            and hook.command == script
            and hook.enabled
            and hook.source == "sessionFlags"
          then
            target = hook
          end
        end
      end
      if target and (target.trustStatus == "trusted" or target.trustStatus == "managed") then
        start_thread()
        return
      end
      -- Match the exact session hook before writing trust. Codex's TUI uses this same
      -- hooks/list key/hash and config/batchWrite upsert route for its review action.
      if
        not after_write
        and target
        and (target.trustStatus == "untrusted" or target.trustStatus == "modified")
        and type(target.key) == "string"
        and type(target.currentHash) == "string"
      then
        request(record, "config/batchWrite", {
          edits = {
            {
              keyPath = "hooks.state",
              value = { [target.key] = { trusted_hash = target.currentHash } },
              mergeStrategy = "upsert",
            },
          },
          reloadUserConfig = true,
        }, function()
          request(record, "hooks/list", { cwds = { params.cwd } }, function(updated)
            check_hook(updated, true)
          end)
        end)
        return
      end
      local review = { vim.fn.shellescape(params.argv[1]) }
      for _, arg in ipairs(params.hook_arg or {}) do
        if arg ~= "--dangerously-bypass-hook-trust" then
          table.insert(review, vim.fn.shellescape(arg))
        end
      end
      fail(
        record,
        "Codex duplex requires a trusted PreToolUse hook: "
          .. script
          .. ". From "
          .. params.cwd
          .. ", run "
          .. table.concat(review, " ")
          .. " and review this hook with /hooks, or use process: oneshot. "
          .. "app-server does not support exec's hook-trust bypass."
      )
    end
    request(record, "hooks/list", { cwds = { params.cwd } }, function(hooks)
      check_hook(hooks, false)
    end)
  end)
end

function M.process_line(record, line, context)
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
        fail(record, "Codex app-server: " .. tostring(msg.error.message or vim.inspect(msg.error)))
      else
        callback(msg.result or {})
      end
    end
  elseif msg.id ~= nil then
    -- PreToolUse handles vibing's UI. Answer native requests too, failing closed.
    local result
    if msg.method == "item/commandExecution/requestApproval" or msg.method == "item/fileChange/requestApproval" then
      result = { decision = "decline" }
    end
    local reply = result and { id = msg.id, result = result }
      or {
        id = msg.id,
        error = { code = -32601, message = "Unsupported Codex request: " .. tostring(msg.method) },
      }
    if not Process.write(record, reply) then
      fail(record, "Could not answer a Codex server request.")
      return
    end
    Processor.processLine(
      vim.json.encode({
        method = "vibing/requestDenied",
        params = {
          message = "Codex requested " .. tostring(msg.method) .. "; this request is not supported in duplex mode.",
        },
      }),
      context
    )
  elseif msg.method then
    notification(record, msg)
  end
end

function M.interrupt(record)
  local rpc = record._rpc
  if not rpc or not rpc.turn_id or rpc.starting_turn then
    return false
  end
  return request(record, "turn/interrupt", { threadId = rpc.thread_id, turnId = rpc.turn_id }, function() end)
end

return M
