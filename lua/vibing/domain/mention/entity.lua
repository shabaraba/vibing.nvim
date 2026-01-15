---@class Vibing.Domain.Mention.Entity
---メンションの集約ルート（Aggregate Root）
---他のSquadからのメンションを表す
local M = {}

local MentionId = require("vibing.domain.mention.value_objects.mention_id")
local MentionStatus = require("vibing.domain.mention.value_objects.mention_status")

---Mentionエンティティを生成
---@param params table { from_squad_name: string, to_squad_name: string, content: string, timestamp?: string, status?: string }
---@return Vibing.Domain.Mention.Entity
function M.new(params)
  assert(params.from_squad_name and params.from_squad_name ~= "", "from_squad_name is required")
  assert(params.to_squad_name and params.to_squad_name ~= "", "to_squad_name is required")
  assert(params.content, "content is required")

  local timestamp = params.timestamp or os.date("%Y-%m-%d %H:%M:%S")
  local id = MentionId.new(params.from_squad_name, timestamp)
  local status = params.status and MentionStatus.new(params.status) or MentionStatus.unprocessed()

  return {
    id = id,
    from_squad_name = params.from_squad_name,
    to_squad_name = params.to_squad_name,
    content = params.content,
    status = status,
    created_at = timestamp,
  }
end

---メンションを処理済みにする
---@param mention Vibing.Domain.Mention.Entity
---@return Vibing.Domain.Mention.Entity 新しいエンティティ（イミュータブル）
function M.mark_as_processed(mention)
  return {
    id = mention.id,
    from_squad_name = mention.from_squad_name,
    to_squad_name = mention.to_squad_name,
    content = mention.content,
    status = MentionStatus.processed(),
    created_at = mention.created_at,
  }
end

---メンションが未処理かどうか
---@param mention Vibing.Domain.Mention.Entity
---@return boolean
function M.is_unprocessed(mention)
  return MentionStatus.is_unprocessed(mention.status)
end

---メンションが処理済みかどうか
---@param mention Vibing.Domain.Mention.Entity
---@return boolean
function M.is_processed(mention)
  return MentionStatus.is_processed(mention.status)
end

---エンティティをシリアライズ可能なテーブルに変換
---@param mention Vibing.Domain.Mention.Entity
---@return table
function M.to_table(mention)
  return {
    id = mention.id.value,
    from_squad_name = mention.from_squad_name,
    to_squad_name = mention.to_squad_name,
    content = mention.content,
    status = mention.status.value,
    created_at = mention.created_at,
  }
end

return M
