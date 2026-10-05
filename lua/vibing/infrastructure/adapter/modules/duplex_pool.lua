--- The resident CLI processes, one per chat, and the four ways they are reclaimed (#777).
---
--- Keyed by chat rather than by session: the chat is what a process serves for its whole life, and
--- it is the value that is stable across a turn (`Vibing.ProcessEntry.chat_bufnr`). A session id is
--- not — turn 1 does not have one yet.
---
--- The restart rule is the only interesting thing here. `transports.wanted(hook, opts)` is decided
--- per turn and `permission_mode` can change between turns from frontmatter, but a resident process
--- was handed its flags once, at spawn. So the argv is the key: a turn whose argv differs from the
--- one the live process was started with cannot honestly be served by it, and the process is
--- replaced with one that resumes the same conversation. The key itself is built by
--- `duplex_stream.reuse_key`, which says why it excludes the resume pair.
--- @module vibing.infrastructure.adapter.modules.duplex_pool

local DuplexProcess = require("vibing.infrastructure.adapter.modules.duplex_process")
local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")

local M = {}

--- A resident process with no turn in flight is ~200MB of RSS doing nothing, plus ~75MB for the
--- MCP server it keeps as a child. Long enough that a reading-and-replying rhythm keeps the process
--- (and its warm prompt cache), short enough that a chat left open over lunch does not. Reviewed
--- when duplex became the default: five minutes is also the prompt cache's own default TTL, so
--- holding the process longer keeps only the startup saving while every idle chat pays the RSS.
M.IDLE_TIMEOUT_MS = 5 * 60 * 1000

--- @alias Vibing.DuplexReclaimReason
--- | "exited"        # the CLI died on its own; the only route that arrives as `on_exit`
--- | "idle"          # `IDLE_TIMEOUT_MS` passed with no turn
--- | "unresponsive"  # the CLI could not be talked to, or never answered
--- | "restart"       # replaced, because a turn cannot honestly be served by it
--- | "shutdown"      # Neovim is exiting
--- | "cancelled"     # killed to stop the turn it was running
--- | "chat_closed"   # the chat it served is gone

--- The reclaim routes after which a turn **is** coming, or there is nobody to tell — so a chat holding
--- unfinished work is left alone (#840). Named as the exemptions rather than as a list of the routes
--- that do report: a reason added later reports by default, and choosing to stay quiet is then a
--- decision somebody wrote down. The opposite default is a reclaim route that silently drops the
--- wake, which is exactly the shape of the hole this closes.
---
--- * `restart` — a turn is being started on the replacement right now, in this same call.
--- * `shutdown` / `chat_closed` — there is nowhere to wake: no event loop left, or no buffer.
--- * `cancelled` — a human stopped this chat on purpose. The same judgement `_cancelled` makes in
---   `application/chat/outstanding_subagents.lua`, made here because on this route there is no
---   response to carry the flag.
---
--- What is left is a process that stopped serving turns while its chat was not looking: the CLI
--- dying, the idle timer, and a CLI that could not be talked to. Whether the work it was holding is
--- also *lost* is a second question, answered differently on one of those three — see
--- `Vibing.DuplexReclaimVerdict`.
--- @type table<Vibing.DuplexReclaimReason, true>
local QUIET_RECLAIM = { restart = true, shutdown = true, cancelled = true, chat_closed = true }

--- @class Vibing.DuplexReclaimVerdict what a reclaim means downstream, resolved from the route here so
--- the vocabulary above reaches no other signature.
--- @field reports boolean whether anybody still needs telling — false on `QUIET_RECLAIM`'s four
--- @field subagents_lost boolean whether the CLI's own children went down with it
---
--- **The two are not the same question, and one route answers them differently.** Every reclaim that
--- goes through `M.stop` kills the tree (`DuplexProcess.stop` → `kill_tree`), so a background subagent
--- running inside that CLI is gone. `exited` does not: the CLI ended on its own, which leaves exactly
--- the state the oneshot transport's ordinary exit leaves — the work may have finished and had its
--- notification dropped, with a transcript on disk to show for it. Collapsing both into one flag is
--- what would have the notice tell the model not to wait for output it could still collect.
--- @param reason Vibing.DuplexReclaimReason|nil
--- @return Vibing.DuplexReclaimVerdict
local function verdict_for(reason)
  return { reports = not QUIET_RECLAIM[reason], subagents_lost = reason ~= "exited" }
end

--- @type table<number|string, Vibing.DuplexProcess>
local records = {}

local leave_autocmd = nil

--- Neovim exiting must not leave a `claude` behind. `VimLeavePre` rather than `VimLeave` because
--- the kill goes through `kill_tree`, which shells out.
local function ensure_leave_hook()
  if leave_autocmd then
    return
  end
  leave_autocmd = vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("VibingDuplexPool", { clear = true }),
    callback = function()
      M.stop_all()
    end,
  })
end

--- @param record Vibing.DuplexProcess
local function cancel_idle_timer(record)
  if record._idle_timer then
    vim.fn.timer_stop(record._idle_timer)
    record._idle_timer = nil
  end
end

--- Forget a process, whether it exited on its own or was stopped.
---
--- **One exit notification per process, on every route out.** Only the CLI dying arrives as an
--- `on_exit` callback; every other route (`Vibing.DuplexReclaimReason`) comes through `M.stop`.
--- Leaving those unannounced left the adapter's `_processes` table holding a handle to a process that
--- no longer exists, which `cleanup_stale_sessions` then reads as "still running" and keeps its
--- session entry alive forever.
--- **What the route meant travels with the notification**, because the routes do not mean the same
--- thing to whoever is told: they are all "the process is gone", and they differ on whether anyone
--- still needs telling and on whether the CLI's children went with it (`Vibing.DuplexReclaimVerdict`).
--- @param chat_key number|string
--- @param record Vibing.DuplexProcess
--- @param code number
--- @param reason Vibing.DuplexReclaimReason
local function forget(chat_key, record, code, reason)
  cancel_idle_timer(record)
  if records[chat_key] == record then
    records[chat_key] = nil
  end
  ProcessRegistry.unregister(record.process_id)
  if not record._gone then
    record._gone = true
    -- Resolved here rather than passed on, because the vocabulary is this module's: handing the
    -- string over would put `Vibing.DuplexReclaimReason` in every downstream signature and let each
    -- consumer re-decide what a route means.
    record._on_gone(record, code, verdict_for(reason))
  end
end

--- @class Vibing.DuplexAcquireSpec
--- @field process_id string minted by the caller, so the child's `VIBING_PROCESS_ID` and the
---   registry entry are decided in one place
--- @field argv string[] what to spawn when a new process is needed (carries `--resume` when there
---   is a session to resume)
--- @field argv_key string the same argv built with no session id; the reuse decision
--- @field cwd string
--- @field env table<string, string>
--- @field process_entry Vibing.ProcessEntry registered when the spawn succeeds
--- @field on_line fun(line: string, record: Vibing.DuplexProcess)
--- @field on_stderr fun(text: string, record: Vibing.DuplexProcess)
--- @field on_exit fun(record: Vibing.DuplexProcess, code: number, verdict: Vibing.DuplexReclaimVerdict)
---   the third argument is what the reclaim route meant, not the route itself

--- The process that will serve this turn: the live one when its argv still matches, a new one
--- otherwise.
--- @param chat_key number|string
--- @param spec Vibing.DuplexAcquireSpec
--- @return Vibing.DuplexProcess|nil record
--- @return string|nil error
function M.acquire(chat_key, spec)
  ensure_leave_hook()

  local existing = records[chat_key]
  if existing then
    -- `_turn` being set means a turn is still open on this process, and a second one must not be
    -- laid on top of it. `ChatBuffer:send_message` guards only `_is_sending` — the `<CR>`-to-spawn
    -- window — and relied on `cancel_request` closing the previous turn *synchronously*, which is
    -- true of a kill and not of an interrupt. Reusing the process here would orphan the open turn
    -- (its registry and permission entries leaking, its `complete` unreachable), hand the
    -- interrupted turn's `result` to the new turn, and leave the old turn's kill-fallback timer
    -- armed to fire into the middle of the new one. Replacing the process instead makes all three
    -- impossible: `M.stop` ends the orphan properly, and a `result` from the old process can no
    -- longer reach the new one.
    local reusable = DuplexProcess.is_alive(existing) and existing.argv_key == spec.argv_key and existing._turn == nil
    if reusable then
      cancel_idle_timer(existing)
      return existing, nil
    end
    M.stop(chat_key, "restart")
  end

  --- Declared before `start` so the exit callback can close over the record it belongs to.
  ---
  --- **It must not ask `records[chat_key]` who died.** `jobstop` only asks: Neovim flushes the
  --- job's streams before firing `on_exit`, while the replacement below is installed synchronously
  --- in this same tick. So a chat-keyed lookup always answers with the *replacement*, and the
  --- dying process's callback then unregisters it, ends its open turn with a bogus exit code, and
  --- orphans a live CLI that no reclaim route can reach any more. The identity check in `forget`
  --- is what makes a late callback from a process that has already been replaced a no-op.
  --- @type Vibing.DuplexProcess|nil
  local record
  local err
  record, err = DuplexProcess.start({
    process_id = spec.process_id,
    argv = spec.argv,
    argv_key = spec.argv_key,
    cwd = spec.cwd,
    env = spec.env,
    on_line = spec.on_line,
    on_stderr = spec.on_stderr,
    on_exit = function(code)
      if record then
        -- Reached only by a process no route here reclaimed first: every deliberate one runs
        -- `forget` before the kill, so `_gone` is already set by the time Neovim flushes the job
        -- and fires this. So this really is "the CLI died on its own".
        forget(chat_key, record, code, "exited")
      end
    end,
  })
  if not record then
    return nil, err
  end

  record._on_gone = spec.on_exit
  records[chat_key] = record
  ProcessRegistry.register(spec.process_entry)
  return record, nil
end

--- The live process serving a chat, or nil.
--- @param chat_key number|string|nil
--- @return Vibing.DuplexProcess|nil
function M.get(chat_key)
  local record = chat_key ~= nil and records[chat_key] or nil
  return record and DuplexProcess.is_alive(record) and record or nil
end

--- The live process with this id, whichever chat it serves. `adapter:cancel()` and the interrupt
--- path are both named by process, never by chat.
--- @param process_id string|nil
--- @return number|string|nil chat_key
--- @return Vibing.DuplexProcess|nil
function M.find_by_process_id(process_id)
  if not process_id then
    return nil, nil
  end
  for chat_key, record in pairs(records) do
    if record.process_id == process_id then
      return chat_key, record
    end
  end
  return nil, nil
end

--- Start counting down to reclaiming an idle process. Called when a turn ends, not when it starts.
--- @param chat_key number|string
function M.release(chat_key)
  local record = records[chat_key]
  if not record then
    return
  end
  cancel_idle_timer(record)
  record._idle_timer = vim.fn.timer_start(M.IDLE_TIMEOUT_MS, function()
    if records[chat_key] == record then
      -- **"Idle" is about turns, not about work.** A background subagent keeps running outside every
      -- turn, so this fires on a process that still has one in flight — and killing it is what makes
      -- that subagent's answer unreachable. The reclaim is still right (a process nobody is talking
      -- to for five minutes is not worth 200MB, and the CLI's own notification has had that long to
      -- arrive), so the resolution is not to hold off but to say so: `idle` orphans, and whoever is
      -- owed a report gets one.
      M.stop(chat_key, "idle")
    end
  end)
end

--- Stop one chat's process now.
--- @param chat_key number|string|nil
--- @param reason Vibing.DuplexReclaimReason every caller names one. Omitting it reports, which is the
---   fail-safe direction rather than a supported call: a reclaim nobody classified is one nobody has
---   decided to keep quiet about.
function M.stop(chat_key, reason)
  local record = chat_key ~= nil and records[chat_key] or nil
  if not record then
    return
  end
  -- Marked before it is announced, not inside `DuplexProcess.stop`: the notification below is what
  -- tells an open turn how it ended, and "the CLI exited with code 0" is a much worse answer than
  -- "Cancelled" for a turn the user cancelled.
  record.stopping = true
  -- Forgotten before it is killed, so the real `on_exit` (which Neovim fires only after flushing
  -- the job's streams, and which `kill_tree` may beat by milliseconds) finds nothing to report
  -- twice. `forget` carries the notification itself for exactly this reason.
  forget(chat_key, record, 0, reason)
  DuplexProcess.stop(record)
end

--- Over a snapshot of the keys, because `stop` removes from the table it would otherwise iterate.
---
--- Always `shutdown`: every caller is Neovim going away, and a reclaim with nowhere to report to is
--- the whole of what that reason means.
function M.stop_all()
  for _, chat_key in ipairs(vim.tbl_keys(records)) do
    M.stop(chat_key, "shutdown")
  end
end

--- Test seam: drop every record without touching the processes they name.
function M._reset()
  for _, record in pairs(records) do
    cancel_idle_timer(record)
  end
  records = {}
end

return M
