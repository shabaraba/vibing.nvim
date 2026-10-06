--- The Codex app-server approval requests that are waiting for a human to answer (#861).
---
--- The third sibling of `pending_approvals.lua` and `pending_questions.lua`, written out rather
--- than factored out — that is the shape #788 chose when the second channel arrived, and the three
--- differ in exactly the part a shared core would have to be parameterised on anyway: **what is
--- being withheld**. An approval withholds a `<request_id>.res` file a shell hook polls; a question
--- withholds the reply to an MCP tool call; this one withholds the **JSON-RPC response to a request
--- the resident CLI sent us**, which is why `respond` is required here as it is next door and
--- absent in the first.
---
--- Four ways out, as in both siblings:
---
---   1. the human answers          → `resolve` with their decision
---   2. the wait limit expires     → the entry's own timer, which declines and runs `on_timeout`
---   3. the chat goes away         → `resolve_for_chat`
---   4. Neovim exits               → `resolve_all`
---
--- …and a fifth that neither sibling has: **codex can resolve its own request**. It announces that
--- with `serverRequest/resolved`, after which writing a response would be answering something that
--- is no longer being asked. `forget` is that exit, and it is the only one that writes nothing.
---
--- **Expiry declines; it does not end the turn.** The asymmetry with `pending_questions.expire` is
--- the one `pending_approvals.expire` already documents: a refusal is something a model can act on,
--- so the turn is worth keeping. It is measured here too — replying `decline` leaves the call
--- un-run, tells the model, and the turn completes normally (codex-cli 0.160.1).
--- @module vibing.infrastructure.rpc.pending_native_approvals

local Decisions = require("vibing.infrastructure.adapter.modules.codex_native_decisions")

local M = {}

--- @class Vibing.PendingNativeApproval
--- @field request_id string what this registry is keyed by
--- @field chat_bufnr number|nil the chat whose prompt answers it
--- @field turn_id string|nil the turn the request belongs to
--- @field tool string|nil what was asked about, for the timeout message
--- @field respond fun(decision: any) writes the JSON-RPC response. Called at most once; `resolve`
---   is what enforces that.
--- @field opened_at number `vim.loop.now()` when the request started waiting
--- @field on_timeout fun(entry: Vibing.PendingNativeApproval)|nil what to do besides declining.
---   **It must not kill anything** — concurrent requests share one turn.
--- @field _timer number|nil

--- @type table<string, Vibing.PendingNativeApproval>
local pending = {}

--- @param entry Vibing.PendingNativeApproval
local function stop_timer(entry)
  if entry._timer then
    pcall(vim.fn.timer_stop, entry._timer)
    entry._timer = nil
  end
end

--- Drop one entry without answering it.
---
--- The fifth exit, and the only one that writes nothing: codex has already resolved the request on
--- its own side (`serverRequest/resolved`), so a response now would name an id it no longer holds.
--- @param request_id string
--- @return boolean forgotten
function M.forget(request_id)
  local entry = pending[request_id]
  if not entry then
    return false
  end
  pending[request_id] = nil
  stop_timer(entry)
  return true
end

--- Answer one waiting request and forget it.
---
--- Idempotent for the same reason as both siblings: the entry is what says a response is still
--- owed, so dropping it first is what makes a second caller a no-op. The write is guarded because
--- it goes to a process that may have died at any point during the wait; a failed write still drops
--- the entry, since nobody is listening.
--- @param request_id string
--- @param decision any the payload for `{ decision = ... }`, as codex offered it
--- @return boolean answered
function M.resolve(request_id, decision)
  local entry = pending[request_id]
  if not entry then
    return false
  end
  pending[request_id] = nil
  stop_timer(entry)

  local ok, err = pcall(entry.respond, decision)
  if not ok then
    vim.notify(
      string.format("[vibing] could not answer the waiting Codex approval %s: %s", request_id, tostring(err)),
      vim.log.levels.WARN
    )
  end
  return true
end

--- Start withholding a response, and arm the limit that guarantees it will not be withheld forever.
--- @param entry Vibing.PendingNativeApproval
--- @return Vibing.PendingNativeApproval
function M.open(entry)
  assert(type(entry.request_id) == "string" and entry.request_id ~= "", "a pending approval needs a request_id")
  assert(type(entry.respond) == "function", "a pending Codex approval needs a way to reply")

  -- Re-opening one id would leave two owners of one response. The id carries the process id, so it
  -- should not happen; decline the old one rather than quietly replacing it.
  M.resolve(entry.request_id, Decisions.refusal())

  entry.opened_at = vim.loop.now()
  pending[entry.request_id] = entry

  local request_id = entry.request_id
  entry._timer = vim.fn.timer_start(
    require("vibing.infrastructure.hooks.wait_budget").approval_wait_sec() * 1000,
    function()
      M.expire(request_id)
    end
  )

  return entry
end

--- Reach the wait limit: refuse that one call, and tell the caller so it can say so.
---
--- `resolve` runs **before** `on_timeout`, the ordering both siblings keep: release what is blocked
--- before anything that writes to a buffer, and leave no window in which the chat's copy is marked
--- expired while a live registry entry would still take an in-place answer.
--- @param request_id string
--- @return boolean expired false when something else answered first
function M.expire(request_id)
  local entry = pending[request_id]
  if not entry then
    return false
  end

  M.resolve(request_id, Decisions.refusal())

  if entry.on_timeout then
    local ok, err = pcall(entry.on_timeout, entry)
    if not ok then
      vim.notify(
        string.format("[vibing] Codex approval timeout fallback failed for %s: %s", request_id, tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
  return true
end

--- @param request_id string
--- @return Vibing.PendingNativeApproval|nil
function M.get(request_id)
  return pending[request_id]
end

--- Every waiting request belonging to one chat, oldest first.
--- @param chat_bufnr number
--- @return Vibing.PendingNativeApproval[]
function M.list_for_chat(chat_bufnr)
  local list = {}
  for _, entry in pairs(pending) do
    if entry.chat_bufnr == chat_bufnr then
      table.insert(list, entry)
    end
  end
  table.sort(list, function(a, b)
    if a.opened_at == b.opened_at then
      return a.request_id < b.request_id
    end
    return a.opened_at < b.opened_at
  end)
  return list
end

--- Whether this chat is holding any Codex request at all. Separate from `list_for_chat` because
--- every caller that only wants the yes/no is on a path that runs per streamed chunk.
--- @param chat_bufnr number
--- @return boolean
function M.has_for_chat(chat_bufnr)
  for _, entry in pairs(pending) do
    if entry.chat_bufnr == chat_bufnr then
      return true
    end
  end
  return false
end

--- @return number
function M.count()
  return vim.tbl_count(pending)
end

--- Answer every request waiting on one chat. The chat closing is not an answer, so it declines.
---
--- The `reason` the shared exit hands over is accepted and dropped: codex's response carries a
--- decision and nothing else, so there is nowhere to put a sentence. Declining rather than
--- cancelling is the choice, and `codex_native_decisions.refusal` is where it is made.
--- @param chat_bufnr number
--- @param _reason string|nil
--- @return number answered
function M.resolve_for_chat(chat_bufnr, _reason)
  local answered = 0
  for _, entry in ipairs(M.list_for_chat(chat_bufnr)) do
    if M.resolve(entry.request_id, Decisions.refusal()) then
      answered = answered + 1
    end
  end
  return answered
end

--- Answer every waiting request, whatever chat it belongs to. Must run **before** the CLI processes
--- are cancelled: a killed CLI can no longer be the thing that stops waiting.
--- @param _reason string|nil
--- @return number answered
function M.resolve_all(_reason)
  local answered = 0
  for _, request_id in ipairs(vim.tbl_keys(pending)) do
    if M.resolve(request_id, Decisions.refusal()) then
      answered = answered + 1
    end
  end
  return answered
end

--- Test seam: drop every entry without answering. Never call this from production code.
function M._reset()
  for _, entry in pairs(pending) do
    stop_timer(entry)
  end
  pending = {}
end

return M
