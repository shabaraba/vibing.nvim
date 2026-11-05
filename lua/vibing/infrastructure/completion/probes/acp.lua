--- Ask an Agent Client Protocol agent which slash commands it advertises.
---
--- `session/new` makes the agent publish `available_commands_update` before any prompt exists, so
--- nothing is sent to the model. Measured 2026-11-05 on commandcode 1.88.2: 33 commands, and no
--- session file written. Not every ACP agent is that clean -- opencode 2.2.5, grok 1.0.67 and
--- copilot 1.0.85 all persist an empty session for each `session/new` (and `session/close` does
--- not remove it), which is why only a descriptor that measured no side effect declares this probe.
--- @module vibing.infrastructure.completion.probes.acp

local LineJob = require("vibing.infrastructure.completion.probes.line_job")

local M = {}

local INITIALIZE_ID = 1
local SESSION_NEW_ID = 2

--- @param update any
--- @return Vibing.CliCommand[]?
local function advertised_commands(update)
  if type(update) ~= "table" or update.sessionUpdate ~= "available_commands_update" then
    return nil
  end
  return type(update.availableCommands) == "table" and update.availableCommands or nil
end

--- @param opts { argv: string[], cwd: string, timeout_ms: integer? }
--- @param callback fun(commands: Vibing.CliCommand[]?)
--- @return boolean started
function M.fetch(opts, callback)
  return LineJob.run({
    argv = opts.argv,
    cwd = opts.cwd,
    timeout_ms = opts.timeout_ms,
    start = function(send)
      send({
        jsonrpc = "2.0",
        id = INITIALIZE_ID,
        method = "initialize",
        params = { protocolVersion = 1, clientCapabilities = vim.empty_dict() },
      })
    end,
    on_message = function(message, send, finish)
      if message.id == INITIALIZE_ID and message.error == nil then
        -- `mcpServers` is required: omitting it is an `Invalid params` error, not a default. An
        -- empty list also keeps the user's MCP servers from being started for a probe.
        send({
          jsonrpc = "2.0",
          id = SESSION_NEW_ID,
          method = "session/new",
          params = { cwd = opts.cwd, mcpServers = {} },
        })
      elseif (message.id == INITIALIZE_ID or message.id == SESSION_NEW_ID) and message.error ~= nil then
        finish(nil)
      elseif message.method == "session/update" then
        local commands = advertised_commands(vim.tbl_get(message, "params", "update"))
        if commands then
          finish(commands)
        end
      end
    end,
  }, callback)
end

return M
