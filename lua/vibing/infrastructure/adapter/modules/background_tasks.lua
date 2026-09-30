--- Background subagents: what was launched, and what never came back.
---
--- A background subagent (`Agent` with `run_in_background`) outlives the turn that launched it.
--- The CLI handles that on its own — it holds the process open, and when the subagent finishes it
--- delivers a `task_notification` and **starts a new turn by itself**. Nothing here makes that
--- happen; vibing only has to stop throwing the events away.
---
--- What this module keeps is the difference between the two: started minus notified. The CLI can
--- drop a notification that lands while the parent is mid-turn (upstream
--- anthropics/claude-code#87675: 19 subagents launched, 15 notified), and that leftover set is
--- what the recovery path goes looking for on disk.
---
--- `task_id` is the same identifier `subagent_marker.lua` scrapes out of the tool result as
--- `agentId`, and the same one naming `subagents/agent-<id>.jsonl`. One id, three places.
---
--- Every function here takes an `owner`: whatever holds the ledger. Under oneshot that is the turn's
--- event context, because the process serves one turn. Under duplex it is the process record, and the
--- contexts are aliased onto it by `M.share` — which is the only reason the parameter is not just
--- called `context`.
--- @module vibing.infrastructure.adapter.modules.background_tasks

local M = {}

--- @class Vibing.BackgroundTask
--- @field task_id string
--- @field description string? the one-line brief the launch carried, when there was one

--- @param owner table
--- @return table<string, Vibing.BackgroundTask>
local function tasks(owner)
  owner._background_tasks = owner._background_tasks or {}
  return owner._background_tasks
end

--- Hand `context` the ledger `owner` keeps, instead of one of its own.
---
--- **The ledger's lifetime has to be the subagents' lifetime, and that is the process, not the
--- turn.** Under oneshot the two are the same thing and this is never called. Under duplex a process
--- serves many turns, and a `task_notification` for a subagent launched in turn N arrives in turn
--- N+1's context — or in the idle context between them, which is where it lands most of the time,
--- since the CLI answers a background completion while nobody is talking to it. A per-turn ledger
--- therefore never sees the notification that would take the entry off it, and every reader of it
--- reports a subagent that reported as one that never did.
--- @param context table
--- @param owner table whatever has the lifetime the ledger must follow (the process record)
function M.share(context, owner)
  context._background_tasks = tasks(owner)
end

--- @param owner table
--- @param event table a `background_task_started` canonical event
function M.started(owner, event)
  if not event.task_id then
    return
  end
  tasks(owner)[event.task_id] = { task_id = event.task_id, description = event.description }
end

--- Take a task off the ledger and hand back what the launch recorded about it.
---
--- Removing rather than flagging is what makes the ledger mean one thing: everything still in it
--- is still owed a notification.
--- @param owner table
--- @param event table a `background_task_done` canonical event
--- @return Vibing.BackgroundTask? nil when the start was never seen
function M.done(owner, event)
  if not event.task_id then
    return nil
  end
  local entry = tasks(owner)[event.task_id]
  tasks(owner)[event.task_id] = nil
  return entry
end

--- Everything launched in the background that never reported back.
--- @param owner table
--- @return Vibing.BackgroundTask[]
function M.unreported(owner)
  local out = {}
  for _, entry in pairs(owner._background_tasks or {}) do
    table.insert(out, entry)
  end
  table.sort(out, function(a, b)
    return a.task_id < b.task_id
  end)
  return out
end

--- What a closing turn owes its chat about the subagents it backgrounded.
---
--- **The ledger travels whether or not anything could be recovered from it**, and whether or not
--- this backend can recover at all: `application/chat/outstanding_subagents.lua` states why, and it
--- is the whole of #820. Recovery is skipped entirely when nothing is outstanding, so the ordinary
--- turn — every turn — touches no disk.
--- @param owner table
--- @param recover Vibing.AdapterDescriptor.recover_unreported_tasks|nil
--- @param cwd string
--- @param session_id string?
--- @return Vibing.BackgroundTask[] unreported everything still owed a completion notification
--- @return Vibing.RecoveredSubagent[] recovered the subset whose transcript already had an answer
function M.report(owner, recover, cwd, session_id)
  local unreported = M.unreported(owner)
  if #unreported == 0 or not recover then
    return unreported, {}
  end
  return unreported, recover(unreported, cwd, session_id) or {}
end

--- @class Vibing.OrphanReportPlan what a resident process needs in order to report its own ledger
--- @field on_orphaned fun(unreported: Vibing.BackgroundTask[], recovered: Vibing.RecoveredSubagent[], subagents_lost: boolean)
--- @field recover Vibing.AdapterDescriptor.recover_unreported_tasks|nil
--- @field adapter table asked for the session id at report time, because turn 1 does not have one yet
---
--- Three plain values, deliberately, rather than the turn that supplied them: this is stored on the
--- process record and the record outlives every turn, so a closure over the turn would pin that
--- turn's whole `event_context` — every streamed chunk of it — for the process's remaining idle life.
--- The cwd is not among them: it is the record's own (`Vibing.DuplexProcess.cwd`), because what is
--- being looked for is what *this process* wrote.

--- Tell whoever is owed about the background subagents still on this process's ledger.
---
--- **Only a process that will serve no more turns may ask this.** Under oneshot the end of the turn is
--- also the end of the process, so `cli_adapter`'s `finish` asks there. Under duplex the process
--- outlives its turns, and asking at the end of one reports every subagent that is merely still
--- running — the regression #838 had to gate off. The moment the question becomes answerable again is
--- `duplex_pool`'s reclaim, and `duplex_routing.exit_handler` is where it is asked (#840).
---
--- Recovery is worth more here than at the end of a turn: minutes passed while the process sat idle,
--- so a subagent that finished in them has written its transcript by now.
--- @param owner table the process record, which is both the ledger owner and where the plan lives
--- @param subagents_lost boolean whether the reclaim took the CLI's children with it — passed straight
---   through, because what it changes is what the chat is *told*, which is not this module's business
function M.report_orphaned(owner, subagents_lost)
  local plan = owner._orphan_report
  if not plan then
    return
  end
  local unreported, recovered =
    M.report(owner, plan.recover, owner.cwd, plan.adapter:get_session_id(owner.process_id))
  if #unreported > 0 then
    plan.on_orphaned(unreported, recovered, subagents_lost)
  end
end

return M
