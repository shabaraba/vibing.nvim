---@class Vibing.Application.MentionUseCase
---メンション機能のユースケース
---Domain層のエンティティとリポジトリを使用してビジネスロジックを実行
local M = {}

local MentionEntity = require("vibing.domain.mention.entity")
local Repository = require("vibing.infrastructure.mention.memory_repository")

---メンションを記録
---@param from_squad_name string 送信元Squad名
---@param to_squad_name string 宛先Squad名
---@param content string メッセージ内容
---@return Vibing.Domain.Mention.Entity 作成されたメンション
function M.record_mention(from_squad_name, to_squad_name, content)
  local mention = MentionEntity.new({
    from_squad_name = from_squad_name,
    to_squad_name = to_squad_name,
    content = content,
  })

  Repository.save(mention)
  return mention
end

---特定Squadの未処理メンションを取得
---@param squad_name string
---@return Vibing.Domain.Mention.Entity[]
function M.get_unprocessed_mentions(squad_name)
  return Repository.find_unprocessed_by_squad(squad_name)
end

---メンションを処理済みにする
---@param mention_id string MentionId.value
function M.mark_mention_processed(mention_id)
  Repository.mark_processed(mention_id)
end

---特定Squadの全メンションを処理済みにする
---@param squad_name string
function M.mark_all_processed(squad_name)
  Repository.mark_all_processed_by_squad(squad_name)
end

---全メンションをクリア（テスト用）
function M.clear_all()
  Repository.clear_all()
end

return M
