--- A turn the resident CLI started by itself, held until the chat adopts it.
---
--- A background subagent finishing makes the CLI emit `task_notification` and answer it on its own,
--- `init` through `result`, while no turn of vibing's is open. Those lines used to reach only the idle
--- context, which has no consumer, so the completion and the model's report never reached the chat
--- and the chat never left `idle`. `handbook/architecture/duplex-transport.md` → "A foreign turn while
--- no vibing turn is open is adopted".
---
--- From the `init` on, the lines are held on the record (`record._foreign`, the array itself) instead.
--- The chat is asked — scheduled, because adopting starts a turn that calls back into the pool — and
--- either opens a turn that replays them (`M.take`) or declines, and they are replayed where they
--- would have gone (`M.flush`). Nothing here writes to the CLI: the turn is already running.
--- @module vibing.infrastructure.adapter.modules.duplex_foreign_turn

local M = {}

--- @class Vibing.CliTurnHandle what the chat layer is handed to settle a held turn
--- @field pending fun(): boolean whether the turn is still waiting to be adopted
--- @field discard fun() give up on adopting it; its lines go where they would have gone

--- Give up on adopting a held turn: replay its lines into the idle context, where they went before
--- this module existed.
---
--- **Must run before a turn of vibing's own opens on the record.** Replayed into that turn, the held
--- `result` would end it — its prompt is not acknowledged yet, so `duplex_turn.ends_this_turn`
--- accepts any `result`. And the held `init` must not start holding all over again, or a chat that
--- declined is asked again on every tick.
--- @param record Vibing.DuplexProcess
function M.flush(record)
  local held = record._foreign
  if not held then
    return
  end
  record._foreign = nil
  record._declining = true
  for _, line in ipairs(held) do
    record.on_line(line, record)
  end
  record._declining = nil
  -- What the declined turn drew is read by nobody, and left here it would open the next held turn's
  -- notice with a whole report that belongs to this one.
  if record._idle_context then
    record._idle_context.output = {}
  end
end

--- Take the held lines for a turn being opened to adopt them. The caller replays them through
--- `record.on_line` once its turn is in place.
--- @param record Vibing.DuplexProcess
--- @return string[]
function M.take(record)
  local held = record._foreign
  record._foreign = nil
  return held or {}
end

--- The idle context saw a turn open. Start holding lines and ask the chat to adopt them.
---
--- What the idle context drew before this — the `Subagent finished` line, decoded from the
--- `task_notification` that preceded the `init` — becomes the notice the adopted turn is announced
--- with, and is taken off the idle context so it cannot accumulate for the process's whole life.
--- @param record Vibing.DuplexProcess
function M.begin(record)
  local on_cli_turn = record._on_cli_turn
  if not on_cli_turn or record._turn or record._foreign or record._gone or record._declining then
    return
  end
  local idle = record._idle_context
  local notice = idle and table.concat(idle.output, "") or ""
  if idle then
    idle.output = {}
  end
  local held = {}
  record._foreign = held

  local handle = {
    pending = function()
      return record._foreign == held and not record._gone
    end,
    discard = function()
      if record._foreign == held then
        M.flush(record)
      end
    end,
  }
  vim.schedule(function()
    if handle.pending() then
      on_cli_turn(notice, handle)
    end
  end)
end

--- Whether the line router must hold `line` instead of decoding it.
--- @param record Vibing.DuplexProcess
--- @param line string
--- @return boolean
function M.hold(record, line)
  if record._foreign and not record._turn then
    table.insert(record._foreign, line)
    return true
  end
  return false
end

--- After a line was decoded: if that line is what started holding (the `init`), hold it too, so the
--- adopted turn sees it — it carries the model and CLI version `### Tokens` reports.
--- @param record Vibing.DuplexProcess
--- @param line string
function M.after_decode(record, line)
  local held = record._foreign
  if held and not record._turn and #held == 0 then
    table.insert(held, line)
  end
end

return M
