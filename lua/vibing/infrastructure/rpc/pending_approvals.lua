--- The hooks that are blocked waiting for a human to answer an approval (#778).
---
--- `bin/hooks/pre-tool-use.sh` polls for a `<request_id>.res` and the CLI sits inside that hook, so
--- withholding the file is what "the turn waits instead of dying" means. Every withheld response is
--- an entry here, and **every entry must eventually be written**: a `.res` that never arrives is a
--- hook spinning to its own deadline and then denying with a generic message, which is the worst of
--- both designs.
---
--- So there are four ways out and no fifth:
---
---   1. the human answers          → `resolve`
---   2. the wait limit expires     → the entry's own timer, which denies and runs `on_timeout`
---   3. the chat goes away         → `resolve_for_chat`
---   4. Neovim exits               → `resolve_all`
---
--- Keyed by `request_id`, because that is what the hook named and what the `.res` path is built
--- from. The chat is carried alongside rather than used as the key: a CLI may have more than one
--- hook blocked at once, and which chat owns the *answer* is a separate question from which
--- request is being answered (#667).
--- @module vibing.infrastructure.rpc.pending_approvals

local HookResponse = require("vibing.infrastructure.rpc.hook_response")

local M = {}

--- @class Vibing.PendingApproval
--- @field request_id string the hook invocation whose `.res` is being withheld
--- @field chat_bufnr number|nil the chat whose prompt answers it
--- @field turn_id string|nil the turn the hook belongs to
--- @field tool string|nil what was asked about, for the timeout message
--- @field opened_at number `vim.loop.now()` when the hook started waiting
--- @field on_timeout fun(entry: Vibing.PendingApproval)|nil what to do besides denying, when the
---   wait limit is reached: kill the turn and say so in the chat, so the fallback is today's
---   behaviour rather than silence
--- @field _timer number|nil

--- @type table<string, Vibing.PendingApproval>
local pending = {}

--- @param entry Vibing.PendingApproval
local function stop_timer(entry)
  if entry._timer then
    pcall(vim.fn.timer_stop, entry._timer)
    entry._timer = nil
  end
end

--- Answer one blocked hook and forget it.
---
--- Idempotent: the entry is what says a decision is still owed, so dropping it is what makes the
--- second caller a no-op. Four different things can reach one request — a human answer, the wait
--- limit, the chat closing, Neovim exiting — and the last three are all cleanup sweeps that run
--- over whatever is left, so "there was nothing to answer" is a normal result and not an error.
--- Returning whether anything was answered is what lets those sweeps report a count.
--- @param request_id string
--- @param decision "allow"|"deny"|"defer"
--- @param reason? string
--- @return boolean answered
function M.resolve(request_id, decision, reason)
  local entry = pending[request_id]
  if not entry then
    return false
  end
  pending[request_id] = nil
  stop_timer(entry)
  HookResponse.write(request_id, decision, reason)
  return true
end

--- Start withholding a response, and arm the limit that guarantees it will not be withheld forever.
---
--- The timer is the whole reason this registry exists rather than a field on the chat buffer. It
--- has to outlive whatever the user does to the UI — closing the window, switching chats, quitting
--- the tab — because what is waiting on it is a CLI process, not a buffer.
--- @param entry Vibing.PendingApproval
--- @return Vibing.PendingApproval
function M.open(entry)
  assert(type(entry.request_id) == "string" and entry.request_id ~= "", "a pending approval needs a request_id")
  -- Re-opening the same request id would leak the previous timer and leave two owners of one
  -- `.res`. It should not happen — the hook mints a fresh id per invocation — so deny the old one
  -- rather than quietly replacing it.
  M.resolve(entry.request_id, "deny", "vibing.nvim received a second approval request under the same id.")

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

--- Reach the wait limit: deny, then let the caller do the rest.
---
--- **The deny goes first, and that ordering is the point.** `on_timeout` is where the turn gets
--- killed and the chat gets its explanatory line, and killing the CLI before releasing its hook
--- would leave an orphaned `pre-tool-use.sh` polling for a process that no longer exists.
---
--- Looked up by id rather than closed over, because the entry under that id may have been resolved
--- and replaced between the timer being armed and firing.
--- @param request_id string
--- @return boolean expired false when something else answered first
function M.expire(request_id)
  local entry = pending[request_id]
  if not entry then
    return false
  end

  local waited = require("vibing.infrastructure.hooks.wait_budget").approval_wait_sec()
  M.resolve(
    request_id,
    "deny",
    string.format(
      "The approval for %s went unanswered for %d seconds, so vibing.nvim denied it. "
        .. "Do not retry this tool immediately.",
      entry.tool or "this tool",
      waited
    )
  )

  if entry.on_timeout then
    -- Guarded: the fallback kills a turn and writes to a buffer, and neither may be allowed to
    -- take down the timer that every other pending approval also runs on.
    local ok, err = pcall(entry.on_timeout, entry)
    if not ok then
      vim.notify(
        string.format("[vibing] approval timeout fallback failed for %s: %s", request_id, tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
  return true
end

--- @param request_id string
--- @return Vibing.PendingApproval|nil
function M.get(request_id)
  return pending[request_id]
end

--- Every blocked hook whose answer belongs to one chat, oldest first.
---
--- Ordered, because when more than one is waiting the oldest is the one closest to its deadline.
--- @param chat_bufnr number
--- @return Vibing.PendingApproval[]
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

--- @return number
function M.count()
  return vim.tbl_count(pending)
end

--- Answer every hook waiting on one chat. The chat closing is not an answer, so it denies.
--- @param chat_bufnr number
--- @param reason? string
--- @return number answered
function M.resolve_for_chat(chat_bufnr, reason)
  local answered = 0
  for _, entry in ipairs(M.list_for_chat(chat_bufnr)) do
    if M.resolve(entry.request_id, "deny", reason) then
      answered = answered + 1
    end
  end
  return answered
end

--- Answer every blocked hook, whatever chat it belongs to.
---
--- Neovim exiting leaves nobody to answer, and a hook that outlives us polls until its own deadline
--- before denying with a generic message. Writing the deny here is what turns that into an
--- immediate, explained refusal — and it must run *before* the CLI processes are cancelled, since a
--- killed CLI can no longer be the thing that stops waiting.
--- @param reason? string
--- @return number answered
function M.resolve_all(reason)
  local answered = 0
  for request_id in pairs(vim.deepcopy(pending)) do
    if M.resolve(request_id, "deny", reason) then
      answered = answered + 1
    end
  end
  return answered
end

--- Test seam: drop every entry without writing anything. Never call this from production code —
--- forgetting a pending approval is exactly the failure this module exists to prevent.
function M._reset()
  for _, entry in pairs(pending) do
    stop_timer(entry)
  end
  pending = {}
end

return M
