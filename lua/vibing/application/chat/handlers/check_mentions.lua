---Slash command handler for /check-mentions
---Displays all unprocessed mentions and marks them as processed
local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
return function(args, chat_buffer)
  if not chat_buffer:has_unprocessed_mentions() then
    notify.info("No unprocessed mentions")
    return true
  end

  local mentions = chat_buffer:get_unprocessed_mentions()

  -- 未処理メンションを表示
  notify.info(string.format("You have %d unprocessed mention(s):", #mentions))

  for i, mention in ipairs(mentions) do
    print(string.format(
      "  [%d] %s from Claude-%s: %s",
      i,
      mention.timestamp,
      mention.from_claude_id,
      vim.split(mention.content, "\n")[1]
    ))
  end

  -- 全て処理済みとしてマーク
  chat_buffer:mark_all_mentions_processed()
  notify.info("All mentions marked as processed")

  return true
end
