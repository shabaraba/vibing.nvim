---@class Vibing.Domain.Mention.MentionStatus
---メンションの処理状態を表す値オブジェクト
local M = {}

---定数
M.UNPROCESSED = "unprocessed"
M.PROCESSED = "processed"

---MentionStatusを生成
---@param value string "unprocessed" | "processed"
---@return Vibing.Domain.Mention.MentionStatus
function M.new(value)
  assert(value == M.UNPROCESSED or value == M.PROCESSED, "Invalid status: " .. tostring(value))

  return {
    value = value,
  }
end

---未処理状態を生成
---@return Vibing.Domain.Mention.MentionStatus
function M.unprocessed()
  return M.new(M.UNPROCESSED)
end

---処理済み状態を生成
---@return Vibing.Domain.Mention.MentionStatus
function M.processed()
  return M.new(M.PROCESSED)
end

---未処理かどうか
---@param status Vibing.Domain.Mention.MentionStatus
---@return boolean
function M.is_unprocessed(status)
  return status.value == M.UNPROCESSED
end

---処理済みかどうか
---@param status Vibing.Domain.Mention.MentionStatus
---@return boolean
function M.is_processed(status)
  return status.value == M.PROCESSED
end

return M
