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
--- @module vibing.infrastructure.adapter.modules.background_tasks

local M = {}

--- @class Vibing.BackgroundTask
--- @field task_id string
--- @field description string? the one-line brief the launch carried, when there was one

--- @param context table
--- @return table<string, Vibing.BackgroundTask>
local function tasks(context)
  context._background_tasks = context._background_tasks or {}
  return context._background_tasks
end

--- @param context table
--- @param event table a `background_task_started` canonical event
function M.started(context, event)
  if not event.task_id then
    return
  end
  tasks(context)[event.task_id] = { task_id = event.task_id, description = event.description }
end

--- Take a task off the ledger and hand back what the launch recorded about it.
---
--- Removing rather than flagging is what makes the ledger mean one thing: everything still in it
--- is still owed a notification.
--- @param context table
--- @param event table a `background_task_done` canonical event
--- @return Vibing.BackgroundTask? nil when the start was never seen
function M.done(context, event)
  if not event.task_id then
    return nil
  end
  local entry = tasks(context)[event.task_id]
  tasks(context)[event.task_id] = nil
  return entry
end

--- Everything launched in the background that never reported back.
--- @param context table
--- @return Vibing.BackgroundTask[]
function M.unreported(context)
  local out = {}
  for _, entry in pairs(context._background_tasks or {}) do
    table.insert(out, entry)
  end
  table.sort(out, function(a, b)
    return a.task_id < b.task_id
  end)
  return out
end

return M
