--- Where a resident CLI process is plugged into the seams the oneshot transport already had.
---
--- Four things reach a process rather than a turn — its stdout, its stderr, its death, and
--- `adapter:cancel()` — and all four were written when those were the same thing. A resident
--- process outlives its turn, so each of them has to ask "which turn is open right now?" instead of
--- closing over one. The answer lives on the process record as `_turn`, and every function here is
--- a reader of it.
---
--- Split from `duplex_stream.lua`, which is about what one turn does.
--- @module vibing.infrastructure.adapter.modules.duplex_routing

local DuplexProcess = require("vibing.infrastructure.adapter.modules.duplex_process")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")

local M = {}

--- The turn a record currently has open, or nil while it is idle.
--- @param record Vibing.DuplexProcess|nil
--- @return table|nil
function M.turn_of(record)
  return record and record._turn or nil
end

--- Take the open turn off a record and hand it back, so a caller cannot end the same turn twice.
--- @param record Vibing.DuplexProcess
--- @return table|nil
local function take_turn(record)
  local turn = M.turn_of(record)
  record._turn = nil
  return turn
end

--- Whether `record` is still the process this chat is using.
---
--- A replaced process goes on flushing whatever Neovim had buffered for it, and those bytes must
--- not be decoded into the replacement's turn — a `result` among them would end a turn that has
--- not produced anything yet. The dying process's callbacks were created for *it*, so identity is
--- the question, never "what is registered for this chat".
--- @param chat_key number|string
--- @param record Vibing.DuplexProcess|nil
--- @return boolean
local function is_current(chat_key, record)
  return record ~= nil and Pool.get(chat_key) == record
end

--- Feed one stdout line to whichever context should see it.
---
--- Between turns the CLI still talks — `active_goal` and `autocompact_state` arrive before the
--- first turn even starts, and the decoder ignores types it does not know. The idle context exists
--- so the one thing that does matter there, the `session` event, still reaches the SessionManager
--- instead of being dropped on the floor with the rest.
--- @param chat_key number|string
--- @param descriptor Vibing.BackendDescriptor
--- @return fun(line: string, record: Vibing.DuplexProcess)
function M.line_router(chat_key, descriptor)
  local control = descriptor.duplex_control
  return function(line, record)
    if not is_current(chat_key, record) then
      return
    end

    -- Answered before the decoder sees it, and **not** gated on there being an open turn: the CLI
    -- is blocked on this reply, so dropping it because the router cannot find a turn would hang
    -- the very turn that asked. The substring test keeps the decode off every ordinary line; it is
    -- a prefilter, and `try_answer` re-checks the shape properly.
    --
    -- The prefilter is safe because of JSON escaping, not because the string is unusual: the same
    -- characters inside a string value arrive as `\"can_use_tool\"` and do not match. Prose about
    -- this feature therefore never reaches the branch (`duplex_stream_spec.lua` asserts it).
    --
    -- `ok and ... try_answer(...)` is an **equivalent mutant** as far as any test goes: dropping
    -- either conjunct only changes what happens to a line that reaches this branch and is not a
    -- permission request, and every such line is one the decoder ignores anyway. Kept as written
    -- because it says what it means, not because a test defends it. Recorded so the next person
    -- does not spend a round trip discovering that, as this one did.
    if control and line:find('"can_use_tool"', 1, true) then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and control.try_answer(msg, function(payload)
        return DuplexProcess.send_control(record, payload)
      end) then
        return
      end
    end

    local turn = M.turn_of(record)
    local context = turn and turn.context or record._idle_context
    if context then
      descriptor.event_processor.processLine(line, context)
    end
  end
end

--- stderr belongs to the turn that was running when it was written, and to the user either way.
---
--- Collected, never announced here: a resident process writes stderr for as long as it lives, so
--- notifying per batch would put one notification on the main loop for every write of an hour-long
--- chat. The oneshot path reports once per process (`stream_handler.create_exit_handler`); the
--- matching boundary for a process that outlives its turns is the turn, so `report_stderr` below is
--- called from `duplex_turn`'s teardown.
--- @param chat_key number|string
--- @return fun(text: string, record: Vibing.DuplexProcess)
function M.stderr_router(chat_key)
  return function(text, record)
    local turn = is_current(chat_key, record) and M.turn_of(record) or nil
    if turn then
      table.insert(turn.context.errorOutput, text)
      return
    end
    -- Between turns there is no context to collect into, and dropping it would lose exactly the
    -- output that explains why the next turn behaves oddly. Carried on the record until one ends.
    record._idle_stderr = record._idle_stderr or {}
    table.insert(record._idle_stderr, text)
  end
end

--- Report the stderr a finishing turn is responsible for: its own, plus anything the process wrote
--- while it was idle and nobody was collecting.
--- @param record Vibing.DuplexProcess
--- @param error_output string[]|nil the finishing turn's collected stderr
function M.report_stderr(record, error_output)
  local parts = record._idle_stderr or {}
  record._idle_stderr = nil
  vim.list_extend(parts, error_output or {})
  StreamHandler.notify_stderr(table.concat(parts, ""))
end

--- What a turn's response looks like when the process, not the turn, ended it.
--- @param record Vibing.DuplexProcess
--- @param turn table
--- @param code number
--- @return Vibing.Response
local function ended_by_process(record, turn, code)
  return {
    content = table.concat(turn.context.output, ""),
    -- `stopping` is set by `duplex_pool.stop` *before* it announces the death, so a turn the user
    -- cancelled says so rather than reporting the exit code of the kill that stopped it.
    error = record.stopping and "Cancelled" or ("The CLI exited with code " .. tostring(code)),
    _cancelled = record.stopping or nil,
    _turn_id = turn.turn_id,
    _process_id = record.process_id,
  }
end

--- The process is gone, by any of the four routes `duplex_pool` reclaims one through.
--- @param adapter table
--- @return fun(record: Vibing.DuplexProcess, code: number)
function M.exit_handler(adapter)
  return function(record, code)
    adapter._processes[record.process_id] = nil
    local turn = take_turn(record)
    if turn then
      turn.complete(ended_by_process(record, turn, code))
    end
  end
end

--- A resident process, made cancellable through the table `adapter:cancel()` already reads.
---
--- `permission.lua`'s `cancel_and_deny` kills rather than interrupting — that is step 4 (#778) —
--- and it reaches the process through here. So a resident process is cancellable exactly the way a
--- per-turn one is; what the next turn does about it is spawn a replacement that resumes.
--- @param record Vibing.DuplexProcess
--- @param chat_key number|string
--- @return table the `{ pid, kill, on_cancel }` surface `cli_runtime.cancel` expects
function M.cancellable_handle(record, chat_key)
  return {
    pid = record.pid,
    kill = function()
      Pool.stop(chat_key)
    end,
    -- Normally a no-op: `Pool.stop` has already announced the death through `exit_handler`, which
    -- took the turn. This is the path for a handle that outlived its pool entry.
    on_cancel = function()
      local turn = take_turn(record)
      if turn then
        turn.complete({
          content = table.concat(turn.context.output, ""),
          error = "Cancelled",
          _cancelled = true,
          _turn_id = turn.turn_id,
          _process_id = record.process_id,
        })
      end
    end,
  }
end

--- Ensure the context lines are fed to between turns, created once per process.
---
--- A mutator despite the name: it fills `record._idle_context` on first call and leaves it alone
--- afterwards, so the decoder's view of the process survives the turns that come and go over it.
--- @param record Vibing.DuplexProcess
--- @param session_manager table
function M.idle_context(record, session_manager)
  record._idle_context = record._idle_context
    or {
      sessionManager = session_manager,
      processId = record.process_id,
      output = {},
      errorOutput = {},
      _decoder_state = record.decoder_state,
    }
end

--- How long an interrupt has to actually stop the turn before the process is killed instead.
---
--- The contract the user sees is "if I say stop, it stops". Keeping the process alive is an
--- optimisation underneath that contract, not a replacement for it: `chansend` succeeding means the
--- bytes were written, never that the CLI acted on them, and a CLI wedged inside a tool call will
--- not act on them at all. Without this, `<C-c>` — which has always killed — would silently become
--- a request the process is free to ignore.
---
--- Measured against claude 2.1.236 mid-generation, the turn ended **16ms** after the interrupt was
--- written. This is ~300x that, on purpose: 16ms is the responsive case, and the case this exists
--- for is the opposite one. So the size comes from how long someone will wait after pressing cancel,
--- and the measurement only says the normal path never reaches it.
--- `handbook/architecture/duplex-transport.md`.
M.INTERRUPT_GRACE_MS = 5000

--- Stop the turn a process has open without stopping the process.
---
--- **"Handled" means the process is resident, not that anything was interrupted.** A chat sends
--- `cancel_request()` before *every* message as a zombie reap (`ChatBuffer:send_message`), so on
--- this transport the common case is being asked to stop a process that is sitting idle between
--- turns — and the caller's fallback for "not handled" is a kill. Returning false there would kill
--- the resident process before every single message, which is the exact opposite of the feature.
---
--- **"Handled" is two different facts, and they must not be conflated.** "This is a resident
--- process, so do not reflexively kill it" is one; "the interrupt was actually delivered" is
--- another. Returning true for the second when only the first is known makes a failed write look
--- like a successful cancel, and the user's stop becomes a no-op until the grace timer notices.
--- So a write that does not land falls straight through to the caller's kill.
---
--- @param adapter table the adapter that owns the process, for the fallback kill
--- @param process_id string|nil
--- @return boolean handled false when there is no resident process, or when it could not be asked
function M.stop_turn(adapter, process_id)
  local _, record = Pool.find_by_process_id(process_id)
  if not record then
    return false
  end

  local turn = M.turn_of(record)
  if not turn then
    -- Idle between turns: there is nothing to stop, and killing would throw the process away on
    -- the zombie reap that precedes every single message.
    return true
  end

  record._interrupts = (record._interrupts or 0) + 1
  if not DuplexProcess.interrupt(record, record._interrupts) then
    -- The request could not even be written -- a dying process, a closed stdin. Waiting out the
    -- grace period would be waiting for an answer to a question nobody was asked.
    return false
  end

  -- Armed through the turn, which stops every timer it owns the moment it ends. A watchdog that
  -- outlived its turn would fire during the *next* one, on the same process, and kill that instead.
  turn.watch(M.INTERRUPT_GRACE_MS, function()
    vim.notify(
      string.format(
        "[vibing] The CLI did not stop within %dms of being interrupted; stopping the process instead.",
        M.INTERRUPT_GRACE_MS
      ),
      vim.log.levels.WARN
    )
    adapter:cancel(record.process_id)
  end)
  return true
end

return M
