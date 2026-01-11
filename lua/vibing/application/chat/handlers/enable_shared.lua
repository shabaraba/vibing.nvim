---Slash command handler for /enable-shared
---Enables shared buffer integration for this chat session
local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
return function(args, chat_buffer)
  chat_buffer:enable_shared_buffer()

  local claude_id = chat_buffer:get_claude_id()
  if claude_id then
    notify.info(string.format("Shared buffer enabled. You are %s", claude_id))
  else
    notify.info("Shared buffer enabled (session not yet started)")
  end

  return true
end
