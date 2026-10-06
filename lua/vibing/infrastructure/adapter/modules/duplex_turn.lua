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
local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")

local M = {}

--- Whether a `result` is the end of *this* turn, or of one the CLI started for itself.
---
--- The CLI runs turns nobody asked for: a background subagent finishing delivers a
--- `task_notification` and the CLI answers it on its own, `init` through `result`, on the same
--- resident process. Measured against claude 2.1.273, one of those lands **between** a prompt being
--- written and the answer to it (`tests/perf/duplex_foreign_turn_end.sh`), so the first `result`
--- after a prompt is routinely not that prompt's. Consuming it ends the turn with nothing in it and
--- sends the real answer to `_idle_context`, where it is dropped — an empty `## Assistant`, and
--- then every later turn off by one.
---
--- The correlation is the CLI's own: the prompt carries a `uuid` and its `result` carries that back
--- as `user_message_uuid`. A self-started turn's carries no such field.
---
--- **A missing field is not evidence of a foreign turn on its own** — a CLI that does not echo at
--- all produces exactly the same `nil`, and rejecting on it would leave the turn open forever. So
--- the gate is armed by proof rather than by assumption: only a turn that has seen its own
--- `prompt_ack` may reject anything, and one that has not keeps the pre-#829 behaviour of ending on
--- the first `result`. The ack arrives on the `queued` state, milliseconds after the write and long
--- before any turn could finish.
--- @param context table the turn's event context
--- @param event table|nil the `turn_end` canonical event
--- @return boolean
function M.ends_this_turn(context, event)
  if not context._prompt_acked then
    return true
  end
  return event ~= nil and event.prompt_uuid == context.promptUuid
end

--- @param params Vibing.DuplexRunParams
--- @param record Vibing.DuplexProcess
--- @param chat_key number|string
--- @param response Vibing.Response
local function hand_back(params, record, chat_key, response)
  if record._turn and record._turn.turn_id == params.ids.turn_id then
    record._turn = nil
  end
  -- Once per turn, which is this transport's answer to the oneshot path's once per process.
  Routing.report_stderr(record, params.event_context.errorOutput)
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
    -- Same value as the oneshot path registers, and it has to be here too: the field is read off
    -- the *turn*, so a duplex chat that omitted it would silently keep killing itself to ask a
    -- question while the oneshot chat next to it did not (#788).
    can_answer_question_in_place = require("vibing.infrastructure.hooks.wait_budget").can_answer_question_in_place(
      params.descriptor and params.descriptor.mcp
    ),
    -- Read off the turn for the same reason, and resolved here rather than in the protocol module
    -- so the gate is asked the same way all three are: from the descriptor, against the configured
    -- budget, with no backend named at the point of use.
    can_wait_for_native_approval = require("vibing.infrastructure.hooks.wait_budget").can_wait_for_native_approval(
      params.descriptor and params.descriptor.native_approval
    ),
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

  -- The process a response names is the one that actually served the turn, which on a reused
  -- process is not the id this turn was minted with. `duplex_stream` has already written it back
  -- onto `ids`; naming `record` here says so without depending on that order.
  local turn_ids = Routing.ids_of(record, record._turn)

  context.onTurnEnd = function(event)
    if not M.ends_this_turn(context, event) then
      return
    end
    local errors = context.resultErrors
    complete(
      TurnOutcome.ended(
        turn_ids,
        table.concat(context.output, ""),
        errors and #errors > 0 and table.concat(errors, "\n") or nil
      )
    )
  end

  -- A resident process that answers nothing at all is indistinguishable from a hung one, and
  -- unlike the oneshot transport there is no exit to notice. Armed on every turn, not only a
  -- resumed one — which is the one thing this watchdog does not share with the oneshot path.
  first_response_timer = vim.fn.timer_start(TurnOutcome.FIRST_RESPONSE_TIMEOUT_MS, function()
    vim.schedule(function()
      if completed then
        return
      end
      vim.notify(string.format("%s The resident CLI process did not answer; restarting it.", params.tag), vim.log.levels.WARN)
      -- Reported before the kill, for the reason `turn_outcome.first_response_timeout` states.
      complete(TurnOutcome.first_response_timeout(turn_ids))
      Pool.stop(chat_key, "unresponsive")
    end)
  end)

  return complete
end

return M
