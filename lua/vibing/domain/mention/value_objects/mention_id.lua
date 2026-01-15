---@class Vibing.Domain.Mention.MentionId
---メンションの一意識別子を表す値オブジェクト
---from_squad_name + timestamp で構成される
local M = {}

---MentionIdを生成
---@param from_squad_name string 送信元Squad名
---@param timestamp string タイムスタンプ
---@return Vibing.Domain.Mention.MentionId
function M.new(from_squad_name, timestamp)
  assert(from_squad_name and from_squad_name ~= "", "from_squad_name is required")
  assert(timestamp and timestamp ~= "", "timestamp is required")

  return {
    value = from_squad_name .. "-" .. timestamp,
    from_squad_name = from_squad_name,
    timestamp = timestamp,
  }
end

---文字列からMentionIdを復元
---@param value string "from_squad_name-timestamp" 形式
---@return Vibing.Domain.Mention.MentionId?
function M.from_string(value)
  if not value or value == "" then
    return nil
  end

  local from_squad_name, timestamp = value:match("^(.+)-(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)$")
  if not from_squad_name or not timestamp then
    return nil
  end

  return M.new(from_squad_name, timestamp)
end

---MentionIdが等しいか比較
---@param a Vibing.Domain.Mention.MentionId
---@param b Vibing.Domain.Mention.MentionId
---@return boolean
function M.equals(a, b)
  return a.value == b.value
end

return M
