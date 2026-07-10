--- Registry for active stream callbacks
--- Allows RPC handlers (e.g., permission hook) to access chat buffer callbacks
--- @module vibing.infrastructure.adapter.modules.active_stream_registry

local M = {}

--- @class ActiveStreamEntry
--- @field handle_id string
--- @field adapter table ClaudeCLI adapter reference
--- @field on_insert_choices? fun(questions: table)
--- @field on_approval_required? fun(tool: string, input: table, options: table, hook_request_id?: string)

--- Keyed by handle_id so concurrent chat buffers each resolve to their own stream instead of
--- one buffer's PreToolUse hook silently grabbing another buffer's callbacks.
--- @type table<string, ActiveStreamEntry>
local streams = {}

--- Register an active stream's callbacks
--- @param entry ActiveStreamEntry
function M.register(entry)
  streams[entry.handle_id] = entry
end

--- Unregister a stream
--- @param handle_id string
function M.unregister(handle_id)
  streams[handle_id] = nil
end

--- Get an active stream entry by handle_id.
--- @param handle_id string|nil The requesting hook process's handle_id (passed via the
---   VIBING_HANDLE_ID env var). When nil (e.g. a hook process spawned before this env var
---   existed), falls back to the sole registered stream if exactly one is active — safe only
---   because there's no other candidate to confuse it with. With multiple concurrent streams
---   and no handle_id, returns nil rather than guessing which chat buffer triggered the hook.
--- @return ActiveStreamEntry|nil
function M.get(handle_id)
  if handle_id then
    return streams[handle_id]
  end

  local only_handle_id, only_entry = next(streams)
  if only_handle_id ~= nil and next(streams, only_handle_id) == nil then
    return only_entry
  end
  return nil
end

return M
