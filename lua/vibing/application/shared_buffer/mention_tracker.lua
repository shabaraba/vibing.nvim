---Mention tracker for tracking processed and unprocessed mentions
---Ensures that Claude sessions respond to mentions before continuing with other tasks
local M = {}

---@class MentionRecord
---@field message_id string Unique identifier for the message (timestamp + from_claude_id)
---@field timestamp string
---@field from_claude_id string
---@field content string
---@field processed boolean Whether this mention has been processed

---@type table<string, table<string, MentionRecord>> claude_id -> message_id -> MentionRecord
local mention_history = {}

---未処理メンションを記録
---@param claude_id string 受信側のClaude ID
---@param message SharedMessage
function M.record_mention(claude_id, message)
  if not mention_history[claude_id] then
    mention_history[claude_id] = {}
  end

  local message_id = message.timestamp .. "-" .. message.from_claude_id
  mention_history[claude_id][message_id] = {
    message_id = message_id,
    timestamp = message.timestamp,
    from_claude_id = message.from_claude_id,
    content = message.content,
    processed = false,
  }
end

---メンションを処理済みとしてマーク
---@param claude_id string
---@param message_id string
function M.mark_processed(claude_id, message_id)
  if mention_history[claude_id] and mention_history[claude_id][message_id] then
    mention_history[claude_id][message_id].processed = true
  end
end

---全てのメンションを処理済みとしてマーク
---@param claude_id string
function M.mark_all_processed(claude_id)
  if not mention_history[claude_id] then
    return
  end

  for message_id, _ in pairs(mention_history[claude_id]) do
    mention_history[claude_id][message_id].processed = true
  end
end

---未処理メンションを取得
---@param claude_id string
---@return MentionRecord[]
function M.get_unprocessed_mentions(claude_id)
  if not mention_history[claude_id] then
    return {}
  end

  local unprocessed = {}
  for _, mention in pairs(mention_history[claude_id]) do
    if not mention.processed then
      table.insert(unprocessed, mention)
    end
  end

  -- タイムスタンプでソート（古い順）
  table.sort(unprocessed, function(a, b)
    return a.timestamp < b.timestamp
  end)

  return unprocessed
end

---未処理メンション数を取得
---@param claude_id string
---@return number
function M.get_unprocessed_count(claude_id)
  local unprocessed = M.get_unprocessed_mentions(claude_id)
  return #unprocessed
end

---特定のメッセージが処理済みか確認
---@param claude_id string
---@param message_id string
---@return boolean
function M.is_processed(claude_id, message_id)
  if not mention_history[claude_id] or not mention_history[claude_id][message_id] then
    return false
  end
  return mention_history[claude_id][message_id].processed
end

---メンション履歴をクリア（テスト用）
---@param claude_id? string 指定した場合はそのClaude IDのみクリア、nilの場合は全てクリア
function M.clear_history(claude_id)
  if claude_id then
    mention_history[claude_id] = {}
  else
    mention_history = {}
  end
end

---メンション履歴を取得（デバッグ用）
---@param claude_id string
---@return table<string, MentionRecord>
function M.get_history(claude_id)
  return mention_history[claude_id] or {}
end

---メンションサマリーを取得
---@param claude_id string
---@return {total: number, processed: number, unprocessed: number}
function M.get_summary(claude_id)
  if not mention_history[claude_id] then
    return { total = 0, processed = 0, unprocessed = 0 }
  end

  local total = 0
  local processed = 0
  local unprocessed = 0

  for _, mention in pairs(mention_history[claude_id]) do
    total = total + 1
    if mention.processed then
      processed = processed + 1
    else
      unprocessed = unprocessed + 1
    end
  end

  return { total = total, processed = processed, unprocessed = unprocessed }
end

return M
