--- The `nvim_ask_user_question` calls that are waiting for a human to answer (#788).
---
--- The sibling of `pending_approvals.lua`, and deliberately the same shape: one entry per answer
--- that is owed, and **every entry must eventually be answered**. What differs is only what is
--- being withheld. An approval withholds a `<request_id>.res` file that a shell hook is polling;
--- a question withholds the **reply to an MCP tool call**, which the CLI is blocked awaiting.
---
--- That difference is why this module exists rather than a flag on the other one. The hook could
--- already block before #778 — not writing the file was the whole mechanism. Nothing here could
--- block before #788: `rpc/server.lua` answered every request from its handler's return value, so
--- the ability to reply later had to be added, and `entry.respond` is that ability held open.
---
--- Four ways out and no fifth, exactly as next door:
---
---   1. the human answers          → `resolve` with their text
---   2. the wait limit expires     → the entry's own timer, which reports the non-answer
---   3. the chat goes away         → `resolve_for_chat`
---   4. Neovim exits               → `resolve_all`
---
--- A fifth would be a CLI blocked inside a tool call until its own MCP idle timeout, which is
--- 1800s on claude — half an hour of a chat that looks alive and is not.
--- @module vibing.infrastructure.rpc.pending_questions

local M = {}

--- @class Vibing.PendingQuestion
--- @field request_id string what the registry is keyed by
--- @field chat_bufnr number|nil the chat whose answer this is
--- @field turn_id string|nil the turn the MCP call belongs to
--- @field questions table[] the question structures, as the model sent them
--- @field respond fun(result: table) writes the RPC reply the MCP server is waiting on. Called at
---   most once; `resolve` is what enforces that.
--- @field opened_at number `vim.loop.now()` when the call started waiting
--- @field on_timeout fun(entry: Vibing.PendingQuestion)|nil what to do besides replying, when the
---   wait limit is reached
--- @field _timer number|nil

--- @type table<string, Vibing.PendingQuestion>
local pending = {}

--- @param entry Vibing.PendingQuestion
local function stop_timer(entry)
  if entry._timer then
    pcall(vim.fn.timer_stop, entry._timer)
    entry._timer = nil
  end
end

--- Reply to one waiting call and forget it.
---
--- Idempotent, for the same reason as `pending_approvals.resolve`: the entry is what says a reply
--- is still owed, so dropping it is what makes a second caller a no-op. Three of the four exits are
--- cleanup sweeps that run over whatever is left, so "there was nothing to answer" is a normal
--- result rather than an error.
---
--- The reply is guarded because it writes to a socket that may have gone away — the MCP server
--- process dies with the CLI it serves, and the CLI can die at any point in this wait. A failed
--- write still drops the entry: nobody is listening, so continuing to hold it open would only make
--- the sweeps report work they cannot do.
--- @param request_id string
--- @param result table the RPC result, as `ask_user_question` would have returned it
--- @return boolean answered
function M.resolve(request_id, result)
  local entry = pending[request_id]
  if not entry then
    return false
  end
  pending[request_id] = nil
  stop_timer(entry)

  local ok, err = pcall(entry.respond, result)
  if not ok then
    vim.notify(
      string.format("[vibing] could not reply to the waiting question %s: %s", request_id, tostring(err)),
      vim.log.levels.WARN
    )
  end
  return true
end

--- The reply that says a human did not answer.
---
--- **Not an error result**, and that is a decision rather than a detail (#788). An error is what a
--- model retries, and retrying this one means asking the same question again — so the user comes
--- back to two copies of a prompt they were already looking at. It reports a fact instead.
--- @param reason string
--- @return table
function M.unanswered(reason)
  return { status = "unanswered", reason = reason }
end

--- Start withholding a reply, and arm the limit that guarantees it will not be withheld forever.
---
--- The timer lives here rather than on the chat buffer for the same reason as next door: what is
--- waiting on it is a CLI process, and it has to outlive whatever the user does to the UI.
--- @param entry Vibing.PendingQuestion
--- @return Vibing.PendingQuestion
function M.open(entry)
  assert(type(entry.request_id) == "string" and entry.request_id ~= "", "a pending question needs a request_id")
  assert(type(entry.respond) == "function", "a pending question needs a way to reply")

  -- Re-opening one id would leave two owners of one reply. The id is minted per call, so it should
  -- not happen; report the old one as unanswered rather than quietly replacing it.
  M.resolve(entry.request_id, M.unanswered("vibing.nvim received a second question under the same id."))

  entry.opened_at = vim.loop.now()
  pending[entry.request_id] = entry

  local request_id = entry.request_id
  entry._timer = vim.fn.timer_start(
    require("vibing.infrastructure.hooks.wait_budget").question_wait_sec() * 1000,
    function()
      M.expire(request_id)
    end
  )

  return entry
end

--- Reach the wait limit.
---
--- **This one ends the turn, where an expiring approval deliberately does not** — but only when
--- nothing else in that turn is still blocked. Both halves matter.
---
--- The asymmetry comes from what a model can do with the reply. An expiring approval says *denied*,
--- and a refusal is a thing a model can act on correctly: it learns the call will not happen and
--- decides what to do next, so the turn is worth keeping. A question has no such answer. "The user
--- did not say which approach they wanted" leaves the choice it asked about still open, and the
--- honest reading of that — pick one and continue — is precisely what the question existed to
--- prevent. So the expiry route is today's route: the reply is written, then the turn ends, and the
--- user's answer arrives later as a new turn exactly as it does now.
---
--- The condition is what keeps that from taking someone else's answer with it. claude dispatches
--- several `tool_use` blocks from one assistant message at once, so a question and an approval hook
--- can be blocked in the same turn — and killing it would throw away an answer the user was in the
--- middle of typing. `ChatBuffer:expire_question` is where that is decided, because the question it
--- asks (*is any prompt still holding this turn*) is about both registries at once.
--- `handbook/architecture/approval-without-kill.md` → "A question has no deny".
---
--- `resolve` runs **before** `on_timeout`, the same ordering as next door and for the first of the
--- same two reasons: release what is blocked before anything that could take the CLI with it.
--- @param request_id string
--- @return boolean expired false when something else answered first
function M.expire(request_id)
  local entry = pending[request_id]
  if not entry then
    return false
  end

  local waited = require("vibing.infrastructure.hooks.wait_budget").question_wait_sec()
  M.resolve(
    request_id,
    M.unanswered(
      string.format(
        "The user did not answer within %d seconds, so vibing.nvim stopped waiting. They may still "
          .. "answer in a later message. Do not ask the same question again immediately.",
        waited
      )
    )
  )

  if entry.on_timeout then
    -- Guarded: it ends a turn and writes to a buffer, and neither may take down the timer every
    -- other pending question also runs on.
    local ok, err = pcall(entry.on_timeout, entry)
    if not ok then
      vim.notify(
        string.format("[vibing] question timeout fallback failed for %s: %s", request_id, tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
  return true
end

--- @param request_id string
--- @return Vibing.PendingQuestion|nil
function M.get(request_id)
  return pending[request_id]
end

--- Every waiting question belonging to one chat, oldest first.
---
--- A list rather than one, even though a CLI awaiting a tool result cannot ordinarily ask twice:
--- claude can emit several tool calls in one assistant message, and a registry that assumed one
--- would drop the second and block that call until the CLI's own 1800s idle timeout.
--- @param chat_bufnr number
--- @return Vibing.PendingQuestion[]
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

--- Whether this chat is holding any question at all.
---
--- Separate from `list_for_chat` for the same reason as next door: every caller that only wants the
--- yes/no is on a path that runs often — `append_chunk` asks once per streamed chunk, `chat_status`
--- once per chat per `nvim_chat_list`, `send_message` once per `<CR>`. Building and sorting a table
--- to compare its length against zero put an allocation and a `table.sort` on the streaming path
--- for an answer that is almost always "no".
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

--- Reply to every question waiting on one chat. The chat closing is not an answer.
--- @param chat_bufnr number
--- @param reason string
--- @return number answered
function M.resolve_for_chat(chat_bufnr, reason)
  local answered = 0
  for _, entry in ipairs(M.list_for_chat(chat_bufnr)) do
    if M.resolve(entry.request_id, M.unanswered(reason)) then
      answered = answered + 1
    end
  end
  return answered
end

--- Reply to every waiting question, whatever chat it belongs to.
---
--- Neovim exiting leaves nobody to answer. It must run **before** the CLI processes are cancelled,
--- since a killed CLI can no longer be the thing that stops waiting — the same ordering the three
--- other shutdown paths owe `pending_approvals`.
--- @param reason string
--- @return number answered
function M.resolve_all(reason)
  -- The ids are collected before any of them is resolved: `resolve` mutates `pending`, and
  -- iterating it directly while removing from it is undefined in Lua. A copy of the *keys* rather
  -- than of the table, because an entry holds a closure and is not a value worth duplicating.
  local ids = {}
  for request_id in pairs(pending) do
    table.insert(ids, request_id)
  end

  local answered = 0
  for _, request_id in ipairs(ids) do
    if M.resolve(request_id, M.unanswered(reason)) then
      answered = answered + 1
    end
  end
  return answered
end

--- Test seam: drop every entry without replying. Never call this from production code — forgetting
--- a pending question is exactly the failure this module exists to prevent.
function M._reset()
  for _, entry in pairs(pending) do
    stop_timer(entry)
  end
  pending = {}
end

return M
