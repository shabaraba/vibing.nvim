---@class Vibing.Infrastructure.RPC.MessageHandler
---RPC handler for programmatic message sending
local M = {}

local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

---Send message to chat buffer
---@param params {bufnr: number, message: string, sender?: string, squad_name?: string}
---@return {success: boolean, bufnr: number}
function M.send_message(params)
  if not params then
    error("Missing parameters")
  end

  -- ProgrammaticSender.send already validates parameters
  return ProgrammaticSender.send(params.bufnr, params.message, params.sender, params.squad_name)
end

return M

