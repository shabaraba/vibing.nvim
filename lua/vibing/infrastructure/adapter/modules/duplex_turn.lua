--- The life of one turn on a resident process: how it is delimited, and how it ends (#777).
---
--- Under the oneshot transport a turn is delimited by the process — it starts when `vim.system`
--- returns and ends when the exit handler runs. Here the process is not a delimiter at all, so both
--- ends have to be stated: the turn starts when the prompt is written and ends on the CLI's own
--- `result` line, which the decoder reports as `turn_end`.
---
--- Both ends are recorded on the process record as `_turn`, because everything that reaches a
--- process rather than a turn (`duplex_routing.lua`) needs to find the open one.
--- @module vibing.infrastructure.adapter.modules.duplex_turn

local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")

local M = {}

--- A resident process that answers nothing at all is indistinguishable from a hung one, and unlike
--- the oneshot transport there is no exit to notice. Armed on every turn, not only a resumed one.
---
--- **Keep this equal to `cli_runtime.INITIAL_RESPONSE_TIMEOUT_MS`.** The two answer the same
--- question — how long to wait for the CLI's first byte — and changing one alone would leave the
--- two transports silently waiting different amounts of time for the same thing. Merging them is
--- #782.
M.FIRST_RESPONSE_TIMEOUT_MS = 120000

--- @param params Vibing.DuplexRunParams
--- @param record Vibing.DuplexProcess
--- @param chat_key number|string
--- @param response Vibing.Response
local function hand_back(params, record, chat_key, response)
  if record._turn and record._turn.turn_id == params.ids.turn_id then
    record._turn = nil
  end
  -- What the process holds on `--resume` is only knowable once the CLI has named it, so the
  -- registry entry `find_other_holding_session` reads is brought up to date here rather than at
  -- registration, where turn 1 has nothing to record.
  local entry = ProcessRegistry.get(record.process_id)
  if entry then
    entry.session_id = params.adapter:get_session_id(record.process_id) or entry.session_id
  end
  Pool.release(chat_key)
  params.finish(response)
end

--- Open a turn on a process that is already running.
---
--- The `TurnRegistry` entry is fresh, which is what makes the two things
--- `processes-and-turns.md` → "What is still owed" asks for fall out rather than needing fixes:
--- `subagent_count` starts at 0, and the previous turn's entry (with whatever it had in flight) is
--- already gone.
---
--- @param params Vibing.DuplexRunParams
--- @param record Vibing.DuplexProcess
--- @param chat_key number|string
--- @return fun(response: Vibing.Response) complete idempotent; ends this turn exactly once
function M.open(params, record, chat_key)
  local ids = params.ids
  local context = params.event_context

  TurnRegistry.open({
    turn_id = ids.turn_id,
    process = ProcessRegistry.get(record.process_id),
    worktree_root = params.opts._worktree_root,
    on_insert_choices = params.opts.on_insert_choices,
    on_approval_required = params.opts.on_approval_required,
  })

  local completed = false
  --- Every timer armed for this turn, so ending the turn releases all of them.
  ---
  --- A timer that outlives its turn is the worst bug shape available here: it fires in the middle
  --- of the *next* turn, on the same resident process, and kills it. So no timer is armed anywhere
  --- except through the turn's own `watch`, and `complete` is the single place they are stopped.
  local timers = {}
  local function stop_timers()
    for _, timer in ipairs(timers) do
      vim.fn.timer_stop(timer)
    end
    timers = {}
  end

  -- The first-response watchdog is the one timer that is disarmed *before* the turn ends, so it is
  -- held apart from the list above. Folding it in would mean `onFirstResponse` also disarmed an
  -- interrupt's kill fallback — which by construction is armed after the first response arrived.
  local first_response_timer = nil
  local function stop_first_response_timer()
    if first_response_timer then
      vim.fn.timer_stop(first_response_timer)
      first_response_timer = nil
    end
  end

  local function complete(response)
    if completed then
      return
    end
    completed = true
    stop_timers()
    stop_first_response_timer()
    hand_back(params, record, chat_key, response)
  end

  record._turn = {
    turn_id = ids.turn_id,
    context = context,
    complete = complete,
    --- Arm a timer that cannot outlive this turn. Returns nothing: the turn owns it.
    --- @param delay_ms number
    --- @param on_expire fun()
    watch = function(delay_ms, on_expire)
      if completed then
        return
      end
      table.insert(
        timers,
        vim.fn.timer_start(delay_ms, function()
          vim.schedule(function()
            if not completed then
              on_expire()
            end
          end)
        end)
      )
    end,
  }

  -- Chained rather than replaced: `cli_adapter` put its own resume-timeout cancel here, and it
  -- still runs on the oneshot path for the same stream.
  local previous = context.onFirstResponse
  context.onFirstResponse = function()
    stop_first_response_timer()
    if previous then
      previous()
    end
  end

  context.onTurnEnd = function()
    local errors = context.resultErrors
    complete({
      content = table.concat(context.output, ""),
      error = errors and #errors > 0 and table.concat(errors, "\n") or nil,
      _turn_id = ids.turn_id,
      _process_id = record.process_id,
    })
  end

  first_response_timer = vim.fn.timer_start(M.FIRST_RESPONSE_TIMEOUT_MS, function()
    vim.schedule(function()
      if completed then
        return
      end
      vim.notify(string.format("%s The resident CLI process did not answer; restarting it.", params.tag), vim.log.levels.WARN)
      -- `complete` first, then the kill. `Pool.stop` announces the death, which reaches this turn
      -- through `duplex_routing.exit_handler` and completes it as a plain "Cancelled" — and since
      -- `complete` is idempotent, the first one through wins. Killing first therefore threw away
      -- the response built below, taking `_session_corrupted` with it: the session was never
      -- reset, no notice was written, and `_cancelled` suppressed the error line too, so a hung
      -- process ended the turn with an empty assistant section and no message at all.
      complete({
        content = "",
        error = "Session resume timeout",
        _session_corrupted = true,
        _old_session_id = params.opts._session_id,
        _turn_id = ids.turn_id,
        _process_id = record.process_id,
      })
      Pool.stop(chat_key)
    end)
  end)

  return complete
end

return M
