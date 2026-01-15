---@class Vibing.Infrastructure.Mention.MemoryRepository
---メンションのインメモリリポジトリ実装
---Domain層のRepositoryインターフェースを実装
local M = {}

local MentionEntity = require("vibing.domain.mention.entity")

---メンション保存用ストレージ
---@type table<string, table<string, Vibing.Domain.Mention.Entity>> squad_name -> mention_id -> Mention
local storage = {}

---メンションを保存
---@param mention Vibing.Domain.Mention.Entity
function M.save(mention)
  local squad_name = mention.to_squad_name
  if not storage[squad_name] then
    storage[squad_name] = {}
  end
  storage[squad_name][mention.id.value] = mention
end

---特定Squadの未処理メンションを取得
---@param squad_name string
---@return Vibing.Domain.Mention.Entity[]
function M.find_unprocessed_by_squad(squad_name)
  local mentions = storage[squad_name]
  if not mentions then
    return {}
  end

  local unprocessed = {}
  for _, mention in pairs(mentions) do
    if MentionEntity.is_unprocessed(mention) then
      table.insert(unprocessed, mention)
    end
  end

  -- タイムスタンプでソート（古い順）
  table.sort(unprocessed, function(a, b)
    return a.created_at < b.created_at
  end)

  return unprocessed
end

---メンションを処理済みにする
---@param mention_id string MentionId.value
function M.mark_processed(mention_id)
  for squad_name, mentions in pairs(storage) do
    local mention = mentions[mention_id]
    if mention then
      storage[squad_name][mention_id] = MentionEntity.mark_as_processed(mention)
      return
    end
  end
end

---特定Squadの全メンションを処理済みにする
---@param squad_name string
function M.mark_all_processed_by_squad(squad_name)
  local mentions = storage[squad_name]
  if not mentions then
    return
  end

  for mention_id, mention in pairs(mentions) do
    if MentionEntity.is_unprocessed(mention) then
      storage[squad_name][mention_id] = MentionEntity.mark_as_processed(mention)
    end
  end
end

---全メンションをクリア（テスト用）
function M.clear_all()
  storage = {}
end

---デバッグ用: 全ストレージを取得
---@return table
function M.get_all_storage()
  return storage
end

return M
