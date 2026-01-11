---Slash command handler for /shared
---Opens the shared buffer for multi-agent coordination
local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
return function(args, chat_buffer)
  local SharedBufferManager = require("vibing.application.shared_buffer.manager")

  -- デフォルトはright、引数があればそれを使用
  local position = args[1] or "right"

  -- 有効な位置のバリデーション
  local valid_positions = { current = true, right = true, left = true, float = true }
  if not valid_positions[position] then
    notify.warn(string.format("Invalid position: %s. Use current, right, left, or float.", position))
    return true
  end

  SharedBufferManager.open_shared_buffer(position)
  notify.info("Shared buffer opened")

  return true
end
