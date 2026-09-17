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

local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")

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

--- Feed one stdout line to whichever context should see it.
---
--- Between turns the CLI still talks — `active_goal` and `autocompact_state` arrive before the
--- first turn even starts, and the decoder ignores types it does not know. The idle context exists
--- so the one thing that does matter there, the `session` event, still reaches the SessionManager
--- instead of being dropped on the floor with the rest.
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

--- @param chat_key number|string
--- @param descriptor Vibing.BackendDescriptor
--- @return fun(line: string, record: Vibing.DuplexProcess)
function M.line_router(chat_key, descriptor)
  return function(line, record)
    if not is_current(chat_key, record) then
      return
    end
    local turn = M.turn_of(record)
    local context = turn and turn.context or record._idle_context
    if context then
      descriptor.event_processor.processLine(line, context)
    end
  end
end

--- stderr belongs to the turn that was running when it was written, and to the user either way.
--- @param chat_key number|string
--- @return fun(text: string, record: Vibing.DuplexProcess)
function M.stderr_router(chat_key)
  return function(text, record)
    local turn = is_current(chat_key, record) and M.turn_of(record) or nil
    if turn then
      table.insert(turn.context.errorOutput, text)
    end
    vim.notify(string.format("[vibing] Process stderr:\n%s", text:sub(1, 500)), vim.log.levels.WARN)
  end
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

--- The context lines are fed to between turns, created once per process.
---  record Vibing.DuplexProcess
---  session_manager table
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

return M
