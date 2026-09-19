--- Which process, and which turn, an inbound hook call belongs to.
---
--- Both shell hooks can only ever name a **process**: `VIBING_PROCESS_ID` is fixed when the child is
--- spawned, so it cannot name a turn once one process serves several (#774). The turn is therefore
--- never on the wire — it is resolved here, at the instant the hook arrives, as the turn that
--- process currently has open.
---
--- **This is the single definition of that resolution, including its one fallback.**
--- `rpc/handlers/permission.lua` used to derive the identity three times per call with two
--- different policies: once for the frontmatter opts, once inside `cancel_and_deny`, and once again
--- to pick a diff baseline key. They agreed only because `cli_adapter.stream()` populated both
--- tables in the same breath — an accident, not a guarantee — and they disagreed on the case below.
---
--- **An id that is present but matches nothing resolves to nil, and does not fall back.** The old
--- `get_active_opts` fell back to the sole entry there, which is a #667-class defect: a hook
--- arriving late, from a turn that had already unregistered, had another chat's `allow` / `deny` /
--- `:once` lists applied to its decision. Returning nil sends the caller to the global config
--- instead, which is the fail-safer of the two answers. The fallback survives only for a hook that
--- named no process at all.
---
--- @module vibing.infrastructure.rpc.hook_scope

local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

local M = {}

--- @class Vibing.HookScope
--- @field process_id string|nil What the hook named, once emptied of the empty string.
--- @field turn_id string|nil The turn that process has open. nil when the process is unknown.
--- @field entry ActiveStreamEntry|nil The stream serving that turn, when one is registered.
--- @field guessed boolean Whether `turn_id` came from the sole-active fallback rather than from the
---   id the hook supplied. Reported rather than hidden because the two callers want different
---   answers: `permission.lua` accepts the guess, `rate_limit.lua` refuses it. Each states its own
---   reason at the point it decides.

--- Resolve one hook call's scope.
---
--- Takes the whole params table rather than the bare id so that a transport able to name its own
--- turn can be honoured here without touching a single call site.
--- @param params table|nil the RPC params as the shell hook sent them
--- @return Vibing.HookScope
function M.of(params)
  local process_id = params and params.process_id or nil
  if process_id == "" then
    process_id = nil
  end

  local entry = ActiveStreamRegistry.find_by_process_id(process_id)
  local guessed = false
  if not entry and not process_id then
    -- The hook named no process: either it predates the variable, or the environment lost it. With
    -- exactly one stream in flight there is no other candidate, so this is a resolution rather than
    -- a coin flip; with several, `sole_active` returns nil.
    entry = ActiveStreamRegistry.sole_active()
    guessed = entry ~= nil
  end

  return {
    process_id = process_id,
    turn_id = entry and entry.handle_id or nil,
    entry = entry,
    guessed = guessed,
  }
end

return M
