---Slash command handler for /post
---Posts a message to the shared buffer with optional mentions
local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("Usage: /post <message> [@Claude-id1 @Claude-id2 ...]")
    return true
  end

  -- 引数全体を結合してメッセージとメンションを抽出
  local full_text = table.concat(args, " ")

  -- メンションを抽出
  local mentions = {}
  for mention in full_text:gmatch("@(Claude%-%w+)") do
    table.insert(mentions, mention)
  end
  for mention in full_text:gmatch("@(All)") do
    table.insert(mentions, mention)
  end

  -- メッセージからメンションを除去
  local content = full_text:gsub("@Claude%-%w+", ""):gsub("@All", ""):gsub("%s+", " ")
  content = vim.trim(content)

  if content == "" then
    notify.warn("Message cannot be empty")
    return true
  end

  -- 共有バッファに投稿
  chat_buffer:post_to_shared_buffer(content, mentions)

  if #mentions > 0 then
    notify.info(string.format("Posted to shared buffer with mentions: %s", table.concat(mentions, ", ")))
  else
    notify.info("Posted to shared buffer")
  end

  return true
end
