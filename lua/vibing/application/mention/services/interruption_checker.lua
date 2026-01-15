---@class Vibing.Application.Mention.InterruptionChecker
---メンションによる割り込み判定サービス
---Agent SDKのcanUseToolから呼ばれる
local M = {}

local MentionUseCase = require("vibing.application.mention.use_case")
local MentionEntity = require("vibing.domain.mention.entity")

---@class InterruptionInfo
---@field has_mentions boolean 未処理メンションがあるか
---@field count number 未処理メンション数
---@field squad_name string 対象Squad名
---@field mentions table[] シリアライズされたメンション配列

---割り込み情報を取得
---@param squad_name string 対象Squad名
---@return InterruptionInfo
function M.get_interruption_info(squad_name)
  if not squad_name or squad_name == "" then
    return { has_mentions = false, count = 0, squad_name = squad_name or "", mentions = {} }
  end

  local raw_mentions = MentionUseCase.get_unprocessed_mentions(squad_name)
  local mentions = {}
  for _, mention in ipairs(raw_mentions) do
    table.insert(mentions, MentionEntity.to_table(mention))
  end

  return {
    has_mentions = #raw_mentions > 0,
    count = #raw_mentions,
    squad_name = squad_name,
    mentions = mentions,
  }
end

return M
