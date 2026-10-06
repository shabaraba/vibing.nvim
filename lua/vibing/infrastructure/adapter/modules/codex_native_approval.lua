--- Codex's own approval requests, routed to the chat that asked for the turn (#861).
---
--- This is **not** the PreToolUse hook. Measured ordering (codex-cli 0.160.1): the hook runs first
--- and, when it denies, codex never sends an approval request at all. So what arrives here is the
--- question the hook's verdict could not answer — *may this call run outside codex's sandbox* —
--- and answering it must not touch vibing's own allow/deny lists. That separation is structural:
--- the prompt this opens carries `kind = "native"`, and `approval_decision` routes a `native`
--- answer to a module that has no access to `update_session_permissions`.
---
--- The reply is the JSON-RPC response to the request codex sent, so it is owed exactly once and
--- forever; `rpc/pending_native_approvals.lua` holds that obligation and its five exits.
--- @module vibing.infrastructure.adapter.modules.codex_native_approval

local Decisions = require("vibing.infrastructure.adapter.modules.codex_native_decisions")
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local Request = require("vibing.infrastructure.adapter.modules.codex_native_request")

local M = {}

--- Restated, never redefined: the word lives with the registry it selects.
M.KIND = require("vibing.infrastructure.rpc.pending_native_approvals").KIND

--- The id this prompt is known by in the chat.
---
--- Codex's own request id is a **small integer that restarts at 0 with every process**, so it
--- cannot be the key: two chats would collide on `0` within seconds of each other, which is the
--- #667 failure through a door #667 did not close. The process id is what makes it unique, and it
--- survives the `[^%s]+` the buffer marker is read back with.
--- @param record Vibing.DuplexProcess
--- @param rpc_id any
--- @return string
function M.request_id(record, rpc_id)
  return string.format("codex-%s-%s", tostring(record.process_id), tostring(rpc_id))
end

--- Remember an item's file changes, so a later `item/fileChange/requestApproval` can show them.
---
--- The approval request carries only an `itemId`; the paths and the diff were in the `item/started`
--- notification that preceded it. Kept on the RPC state, which `start_turn` clears, so the table
--- cannot outlive the turn that filled it.
--- @param rpc table `record._rpc`
--- @param item table|nil
function M.remember_changes(rpc, item)
  if type(item) ~= "table" or item.type ~= "fileChange" or not item.id then
    return
  end
  rpc.file_changes = rpc.file_changes or {}
  rpc.file_changes[item.id] = item.changes
end

--- Answer one of codex's own requests.
---
--- Takes the **channel id**, not the process record. The `respond` closure built below is parked in
--- the registry until a human answers, so capturing the record would keep a process that has since
--- been reclaimed — along with its decoder state and its cached file-change diffs — reachable for
--- the whole wait. Writing never needed more than this (`duplex_process.write_to`).
--- @param job_id number|nil
--- @param rpc_id any
--- @param decision any
--- @return boolean written
local function reply(job_id, rpc_id, decision)
  return Process.write_to(job_id, { id = rpc_id, result = { decision = decision } })
end

--- Codex resolved one of its own requests, so nothing is owed on it any more.
--- @param record Vibing.DuplexProcess
--- @param params table|nil
--- @return boolean forgotten
function M.resolved(record, params)
  local rpc_id = type(params) == "table" and params.requestId or nil
  if rpc_id == nil then
    return false
  end
  return require("vibing.infrastructure.rpc.pending_native_approvals").forget(M.request_id(record, rpc_id))
end

--- Whether this request is one we answer with a decision.
--- @param method string
--- @return boolean
function M.handles(method)
  return Request.METHODS[method] ~= nil
end

--- Take ownership of one approval request.
---
--- Returns whether the request was answered or is now being waited on. `false` means the caller
--- should fall back to its own refusal, so a failure here can never leave codex blocked on a
--- response nobody owes.
--- @param record Vibing.DuplexProcess
--- @param msg table the decoded JSON-RPC request
--- @return boolean handled
function M.handle(record, msg)
  local rpc = record._rpc or {}
  local turn_id = record._turn and record._turn.turn_id or nil
  local turn = turn_id and require("vibing.infrastructure.adapter.modules.turn_registry").get(turn_id) or nil
  local chat_bufnr = turn and turn.process and turn.process.chat_bufnr or nil

  if not (turn and chat_bufnr and turn.can_wait_for_native_approval and turn.on_approval_required) then
    return false
  end

  local params = type(msg.params) == "table" and msg.params or {}
  local changes = params.itemId and (rpc.file_changes or {})[params.itemId] or nil
  local tool, input = Request.describe(msg.method, params, changes)
  local options = Decisions.options(params.availableDecisions)
  local request_id = M.request_id(record, msg.id)
  -- Both captured as scalars, so the closure below holds nothing but what the reply needs.
  local rpc_id, job_id = msg.id, record.job_id

  -- **Register before drawing.** The registry is what arms the wait limit, so anything that throws
  -- below still ends in a decision reaching codex rather than a turn blocked forever.
  require("vibing.infrastructure.rpc.pending_native_approvals").open({
    request_id = request_id,
    chat_bufnr = chat_bufnr,
    turn_id = turn_id,
    tool = tool,
    respond = function(decision)
      reply(job_id, rpc_id, decision)
    end,
    on_timeout = function(entry)
      local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(entry.chat_bufnr)
      if chat_buf and type(chat_buf.expire_approval) == "function" then
        chat_buf:expire_approval(entry)
      end
    end,
  })

  -- No `vim.schedule`: this already runs on the main loop from the job's stdout callback, and a
  -- deferred staging lands after the turn may have consumed it (#649).
  local ok, err = pcall(turn.on_approval_required, tool, input, options, request_id, true, M.KIND)
  if not ok then
    vim.notify(
      string.format("[vibing] could not draw the Codex approval prompt for %s: %s", tool, tostring(err)),
      vim.log.levels.ERROR
    )
  end

  require("vibing.application.chat.completion_notifier").on_approval_waiting(chat_bufnr, request_id)
  return true
end

--- Refuse one request without asking anybody. The path taken when the gate is shut, or when there
--- is no chat to ask — fail closed, exactly as the hook script does.
--- @param record Vibing.DuplexProcess
--- @param rpc_id any
--- @return boolean written
function M.refuse(record, rpc_id)
  return reply(record.job_id, rpc_id, Decisions.refusal())
end

return M
