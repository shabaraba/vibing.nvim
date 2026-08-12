--- Codex's tool names, translated to the canonical vocabulary the rest of vibing.nvim speaks.
---
--- Lives beside the adapter rather than in the permission handler so that shared infrastructure
--- never has to know which backend it is talking to: `codex_cli.lua` hands this module to
--- `set_active_opts` as a generic `_tool_vocabulary`, and the handler just calls whatever it was
--- given. See #516.
--- @module vibing.infrastructure.adapter.modules.codex_tool_vocabulary

local M = {}

--- @type table<string, string>
local NATIVE_TO_CANONICAL = {
  apply_patch = "Edit", -- Codex's file patch tool maps to Claude's Edit
}

--- @param native_tool_name string
--- @return string|nil canonical name, or nil when there is no mapping
function M.to_canonical(native_tool_name)
  return NATIVE_TO_CANONICAL[native_tool_name]
end

return M
