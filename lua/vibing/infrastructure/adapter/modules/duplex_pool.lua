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

--- A resident process with no turn in flight is ~200MB of RSS doing nothing. Long enough that a
--- reading-and-replying rhythm keeps the process (and its warm prompt cache), short enough that a
--- chat left open over lunch does not.
M.IDLE_TIMEOUT_MS = 5 * 60 * 1000

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
--- **One exit notification per process, on every route out.** There are four — the CLI dying, the
--- idle timer, an argv change, and `VimLeavePre` — and only the first of them arrives as an
--- `on_exit` callback. Leaving the other three unannounced left the adapter's `_processes` table
--- holding a handle to a process that no longer exists, which `cleanup_stale_sessions` then reads
--- as "still running" and keeps its session entry alive forever.
--- @param chat_key number|string
--- @param record Vibing.DuplexProcess
--- @param code number
local function forget(chat_key, record, code)
  cancel_idle_timer(record)
  if records[chat_key] == record then
    records[chat_key] = nil
  end
  ProcessRegistry.unregister(record.process_id)
  if not record._gone then
    record._gone = true
    record._on_gone(record, code)
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
--- @field on_line fun(line: string)
--- @field on_stderr fun(text: string)
--- @field on_exit fun(record: Vibing.DuplexProcess, code: number)

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
    M.stop(chat_key)
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
        forget(chat_key, record, code)
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
      M.stop(chat_key)
    end
  end)
end

--- Stop one chat's process now.
--- @param chat_key number|string|nil
function M.stop(chat_key)
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
  forget(chat_key, record, 0)
  DuplexProcess.stop(record)
end

--- Over a snapshot of the keys, because `stop` removes from the table it would otherwise iterate.
function M.stop_all()
  for _, chat_key in ipairs(vim.tbl_keys(records)) do
    M.stop(chat_key)
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
