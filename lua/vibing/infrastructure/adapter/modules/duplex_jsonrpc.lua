--- The stdio JSON-RPC plumbing a resident protocol needs, shared by the backends that speak it.
---
--- Two of them do: codex's `app-server` and grok's `agent stdio` ACP. Both had their own copy of
--- these four functions, identical but for the agent's name in a failure message — so a fix to the
--- turn-completion path or the pool interaction had to be made twice, and the second copy is the one
--- that gets forgotten.
---
--- **What belongs here is everything that is not the protocol.** `fail` and `render` are the turn
--- and the pool, which `architecture.md` → "The Duplex Transport" already says are shared; `request`
--- and `reply` are JSON-RPC itself. What stays in `<backend>_duplex_protocol.lua` is the part that
--- is genuinely the descriptor's: which methods exist, what ends a turn, what a notification means,
--- and which requests the agent may make of us.
--- @module vibing.infrastructure.adapter.modules.duplex_jsonrpc

local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")

local M = {}

--- @class Vibing.DuplexRpc
--- @field fail fun(record: Vibing.DuplexProcess, message: string)
--- @field render fun(record: Vibing.DuplexProcess, msg: table)
--- @field request fun(record: Vibing.DuplexProcess, method: string, params: table, callback: fun(result: table)): boolean
--- @field reply fun(record: Vibing.DuplexProcess, msg: table): boolean

--- Bind the plumbing to one backend's decoder and name.
---
--- @param opts { processor: table, agent: string, jsonrpc: boolean? } `processor` is the backend's
---   `stream_decoder.processor`; `agent` names the agent in a failure message ("Grok agent");
---   `jsonrpc` adds the `"2.0"` member to every outgoing frame. That last one is per backend on
---   purpose: grok's ACP requires it and codex's app-server was measured without it, and sending a
---   member a protocol does not expect is not a change to make on the strength of a tidier default.
--- @return Vibing.DuplexRpc
function M.bind(opts)
  local processor, agent, jsonrpc = opts.processor, opts.agent, opts.jsonrpc
  local rpc = {}

  --- End the turn with an error and retire the process serving it.
  ---
  --- Both halves are needed and in this order: a protocol failure means this connection can no
  --- longer be trusted to serve the next turn, but the turn that is open now still owes the user a
  --- response. Retiring first would complete it from the pool's reclaim path instead, as a cancel.
  --- @param record Vibing.DuplexProcess
  --- @param message string
  function rpc.fail(record, message)
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

  --- Hand one message to the renderer, resolving the turn **now** rather than when the line
  --- arrived: most of what a resident protocol renders comes out of a deferred reply callback, and
  --- a message that arrives between turns belongs to `_idle_context`.
  ---
  --- `msg` is already a Lua table, built locally or decoded off the wire, so it is passed straight
  --- in rather than encoded back to JSON only for the decoder to immediately decode it again.
  --- @param record Vibing.DuplexProcess
  --- @param msg table
  function rpc.render(record, msg)
    local turn = record._turn
    local context = turn and turn.context or record._idle_context
    if context then
      processor.apply(msg, context)
    end
  end

  --- Send a request and remember who answers it.
  ---
  --- The id is per process and monotonic, so two turns on one connection never share one. A write
  --- that fails takes the callback back out before failing the turn — a pending entry nothing will
  --- ever answer is what keeps a reclaimed process's decoder state reachable.
  --- @param record Vibing.DuplexProcess
  --- @param method string
  --- @param params table
  --- @param callback fun(result: table)
  --- @return boolean sent
  function rpc.request(record, method, params, callback)
    local state = record._rpc
    state.seq = state.seq + 1
    local id = "vibing-rpc-" .. state.seq
    state.pending[id] = callback
    local frame = { id = id, method = method, params = params }
    if jsonrpc then
      frame.jsonrpc = "2.0"
    end
    if not Process.write(record, frame) then
      state.pending[id] = nil
      rpc.fail(record, "Could not write " .. method .. " to the " .. agent .. ".")
      return false
    end
    return true
  end

  --- Dispatch a correlated response to whoever asked for it.
  ---
  --- An `error` fails the turn rather than reaching the callback, because every caller's success
  --- path assumes a result. `data` is included when the agent sent one: it is where a JSON-RPC
  --- implementation says *what* was wrong, and `message` alone is routinely "Invalid params",
  --- which names no field.
  --- @param record Vibing.DuplexProcess
  --- @param msg table a decoded frame with an `id` and no `method`
  --- @return boolean was_a_response always true; returned so a caller can `return rpc.reply(...)`
  function rpc.reply(record, msg)
    local state = record._rpc
    local callback = state.pending[msg.id]
    state.pending[msg.id] = nil
    if not callback then
      return true
    end
    if msg.error then
      local detail = msg.error.message or vim.inspect(msg.error)
      if msg.error.data then
        detail = detail .. ": " .. tostring(msg.error.data)
      end
      rpc.fail(record, agent .. ": " .. tostring(detail))
    else
      callback(msg.result or {})
    end
    return true
  end

  return rpc
end

return M
