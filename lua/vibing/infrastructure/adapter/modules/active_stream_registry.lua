--- Registry for active stream callbacks
--- Allows RPC handlers (e.g., permission hook) to access chat buffer callbacks
--- @module vibing.infrastructure.adapter.modules.active_stream_registry

local M = {}

--- @class ActiveStreamEntry
--- @field handle_id string
--- @field adapter table ClaudeCLI adapter reference
--- @field on_insert_choices? fun(questions: table)
--- @field on_approval_required? fun(tool: string, input: table, options: table, hook_request_id?: string)

--- @type ActiveStreamEntry|nil
local current_stream = nil

--- Register an active stream's callbacks
--- @param entry ActiveStreamEntry
function M.register(entry)
  current_stream = entry
end

--- Unregister the active stream
--- @param handle_id string Only unregister if handle_id matches
function M.unregister(handle_id)
  if current_stream and current_stream.handle_id == handle_id then
    current_stream = nil
  end
end

--- Get the current active stream entry
--- @return ActiveStreamEntry|nil
function M.get()
  return current_stream
end

return M
