local notify = require("vibing.core.utils.notify")

local M = {}

---特定のClaude IDにメンションを送る
---@param args table コマンド引数
function M.execute(args)
  local chat_controller = require("vibing.presentation.chat.controller")
  local chat_buffer = chat_controller.get_active_chat_buffer()

  if not chat_buffer then
    notify.warn("No active chat buffer. Open a chat first with :VibingChat")
    return
  end

  if not chat_buffer._shared_buffer_enabled then
    notify.warn("Shared buffer integration is not enabled. Enable it with /enable-shared")
    return
  end

  -- Parse arguments: :VibingMention Claude-abc12 Message content here
  local args_str = args.args or ""
  local claude_id, message = args_str:match("^(%S+)%s+(.+)$")

  if not claude_id or not message then
    notify.error("Usage: :VibingMention <claude-id> <message>")
    notify.info("Example: :VibingMention Claude-abc12 Need help with testing")
    return
  end

  -- Validate claude_id format
  if not claude_id:match("^Claude%-%w+$") then
    notify.error("Invalid Claude ID format. Expected: Claude-{id}")
    return
  end

  -- Post to shared buffer with mention
  chat_buffer:post_to_shared_buffer(message, { claude_id })

  notify.info(string.format("Mentioned %s in shared buffer", claude_id))
end

return M
