--- The CLI processes vibing.nvim currently has alive.
---
--- A process outlives any one turn (#774), so everything here is asked about *holding* rather than
--- about *running*: which conversation a process has open on `--resume`, which chat it serves, and
--- which adapter can kill it. What it is doing right now is `turn_registry.lua`'s question, and the
--- dependency runs only that way — this module requires nothing from there.
---
--- @module vibing.infrastructure.adapter.modules.process_registry

local M = {}

--- @class Vibing.ProcessEntry
--- @field process_id string The child's `VIBING_PROCESS_ID`, the key of `adapter._processes`, the
---   only thing `adapter:cancel()` accepts, and the key of the table below.
--- @field session_id? string The CLI session this process holds open. A process keeps its
---   `--resume <id>` for as long as it lives, whether or not a turn is in flight, which is why the
---   same-session refusal below asks this registry and not the turn one: two processes resuming one
---   session write the same transcript concurrently. Two chat buffers can be bound to one session
---   (a subagent chat shares its parent's), so this really can collide.
--- @field chat_bufnr? number Stable value (the "Current vibing.nvim chat buffer number" line
---   embedded in the model-visible provider prompt) used to route nvim_ask_user_question calls
---   without a per-turn id, which would otherwise defeat provider prompt caching (see issues #469,
---   #489). Per process rather than per turn because it names the chat, and the chat is what the
---   process serves for its whole life.
--- @field adapter table backend adapter reference; the receiver of `cancel(process_id)`
--- @field active_turn_id? string The turn this process currently has open, or nil while it is idle.
---   **Written only by `turn_registry.open` / `close`.** It is the one link between the two
---   registries, and keeping the writer in one module is what stops it from drifting out of step
---   with the turn table itself.

--- @type table<string, Vibing.ProcessEntry>
local processes = {}

--- The first entry the predicate accepts, or nil. Both lookups below a key lookup are a scan of
--- this table, and they are written once here so the two of them cannot drift apart.
--- @param predicate fun(entry: Vibing.ProcessEntry): boolean
--- @return Vibing.ProcessEntry|nil
local function find(predicate)
  for _, entry in pairs(processes) do
    if predicate(entry) then
      return entry
    end
  end
  return nil
end

--- Record a CLI process as alive.
--- @param entry Vibing.ProcessEntry
function M.register(entry)
  processes[entry.process_id] = entry
end

--- Record a CLI process as gone. Any turn it still had open must be closed first, or
--- `turn_registry` is left holding an entry whose process is no longer reachable.
--- @param process_id string
function M.unregister(process_id)
  processes[process_id] = nil
end

--- The process an inbound hook named.
---
--- The inbound path for both shell hooks: `VIBING_PROCESS_ID` is fixed at spawn, so a process is the
--- only thing a hook can name, and the turn is resolved from here rather than travelling on the
--- wire (`rpc/hook_scope.lua`). **Deliberately strict** — an unmatched id returns nil instead of
--- guessing at the sole live process. The caller decides whether to guess, because the two callers
--- want different answers: an approval prompt shown in the wrong buffer is recoverable, and a diff
--- baseline opened under the wrong turn silently mis-attributes another chat's edits.
--- @param process_id string|nil
--- @return Vibing.ProcessEntry|nil
function M.get(process_id)
  if not process_id then
    return nil
  end
  return processes[process_id]
end

--- The process serving a given chat buffer.
--- @param chat_bufnr number|nil
--- @return Vibing.ProcessEntry|nil
function M.find_by_chat_bufnr(chat_bufnr)
  if not chat_bufnr then
    return nil
  end
  return find(function(entry)
    return entry.chat_bufnr == chat_bufnr
  end)
end

--- Another buffer's process that is holding the same CLI session open.
---
--- **Holding, not running.** A resident process keeps its `--resume <id>` between turns, so asking
--- "is another turn in flight on this session" would let a second process attach to the same
--- transcript the moment the first one went idle — exactly the corruption #756 refuses. Asking who
--- *holds* the session stays correct under both transports.
--- @param session_id string|nil
--- @param exclude_chat_bufnr number|nil the buffer asking; its own process is not a conflict
--- @return Vibing.ProcessEntry|nil
function M.find_other_holding_session(session_id, exclude_chat_bufnr)
  if not session_id or session_id == "" then
    return nil
  end
  return find(function(entry)
    return entry.session_id == session_id and entry.chat_bufnr ~= exclude_chat_bufnr
  end)
end

return M
