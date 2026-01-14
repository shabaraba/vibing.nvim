---@class Vibing.Infrastructure.RPC.MessageHandler
---RPC handler for programmatic message sending
local M = {}

local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

---Send message to chat buffer
---@param params {bufnr: number, message: string, sender?: string}
---@return {success: boolean, bufnr: number}
function M.send_message(params)
  local bufnr = params and params.bufnr
  local message = params and params.message
  local sender = params and params.sender

  -- Parameter validation
  if not bufnr then
    error("Missing required parameter: bufnr")
  end

  if not message or message == "" then
    error("Missing required parameter: message")
  end

  -- Execute message send (errors are propagated via error())
  local result = ProgrammaticSender.send(bufnr, message, sender)

  return result
end

return M

