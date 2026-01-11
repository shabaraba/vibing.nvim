---Slash command handler for /disable-shared
---Disables shared buffer integration for this chat session
local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
return function(args, chat_buffer)
  chat_buffer:disable_shared_buffer()
  notify.info("Shared buffer disabled")

  return true
end
