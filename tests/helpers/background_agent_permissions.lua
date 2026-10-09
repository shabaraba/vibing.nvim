--- 裏のエージェントに渡すオプションが、フック側の権限判定でどう決まるかを引く。
--- `rpc/handlers/permission.lua` の `build_permission_config` と同じ読み方で `can_use_tool` に渡す。
local M = {}

local can_use_tool = require("vibing.infrastructure.permissions.can_use_tool")

---@param opts Vibing.AdapterOpts
---@param tool string
---@param input table
---@return "allow"|"deny"|"ask"
function M.decide(opts, tool, input)
  return can_use_tool.can_use_tool(tool, input, {
    allowed_tools = opts.permissions_allow or {},
    denied_tools = opts.permissions_deny or {},
    asked_tools = {},
    session_allowed_tools = {},
    session_denied_tools = {},
    permission_rules = {},
    permission_mode = opts.permission_mode,
    mcp_enabled = true,
    exclusive_tools = opts.exclusive_tools,
  }).behavior
end

return M
