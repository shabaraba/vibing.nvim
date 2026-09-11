--- Show a message from a process that has no other way to reach the user.
---
--- The one caller is the MCP server's launcher (`claude-plugin/mcp-server/bin/notify-nvim.mjs`),
--- which runs before the server exists and so cannot report through a tool result. Its `stderr`
--- reaches neither the CLI's own streams nor anything the user reads -- measured; the reasoning is
--- in that file -- so a message about the launcher missing Claude Code's 30s startup deadline had
--- nowhere to go, and the whole tool set disappearing from a session looked like nothing at all
--- (#690).
---
--- This is deliberately not `execute`: a caller that only needs to say something should not have
--- to be trusted with running Lua.
--- @module vibing.infrastructure.rpc.handlers.notify

local Notify = require("vibing.core.utils.notify")

local M = {}

--- @type table<string, fun(message: string, action: string?)>
local BY_LEVEL = {
  info = Notify.info,
  warn = Notify.warn,
  error = Notify.error,
}

--- @param params table? { message: string, level: string?, title: string? }
--- @return table
function M.notify(params)
  params = params or {}

  local message = params.message
  if type(message) ~= "string" or message == "" then
    error("notify requires a non-empty message")
  end

  -- An unrecognised level is shown rather than dropped: the point of this handler is that the
  -- caller has no second channel to report the mistake on.
  local emit = BY_LEVEL[params.level] or Notify.info
  emit(message, type(params.title) == "string" and params.title or nil)

  return { success = true }
end

return M
