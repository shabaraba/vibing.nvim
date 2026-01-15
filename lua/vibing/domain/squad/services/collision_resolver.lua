---@class Vibing.Domain.Squad.CollisionResolver
---分隊名の衝突解決ロジック
local M = {}

local SquadName = require("vibing.domain.squad.value_objects.squad_name")

---分隊名の衝突を検出し、代替名を提案
---@param desired_name string 希望する分隊名
---@param registry table SquadRegistry
---@return table resolution { has_collision: boolean, alternative_name?: string, notice_message?: string }
function M.resolve_collision(desired_name, registry)
  -- 1. 衝突判定
  if registry.is_available(desired_name) then
    return {
      has_collision = false,
    }
  end

  -- 2. 未使用の代替名を検索
  local active_squads = registry.get_all_active()
  local used_names = {}

  for name, _ in pairs(active_squads) do
    used_names[name] = true
  end

  local alternative_name = SquadName.get_next_available(used_names)

  if not alternative_name then
    -- 全て使用中の場合（26個の上限）
    return {
      has_collision = true,
      alternative_name = nil,
      notice_message = string.format(
        "分隊名 %s は既に使用中ですが、全ての分隊名が使用中のため代替名を割り当てられませんでした。",
        desired_name
      ),
    }
  end

  -- 3. 衝突情報を返却（通知用）
  return {
    has_collision = true,
    alternative_name = alternative_name,
    notice_message = string.format(
      "分隊名 %s は既に使用中のため、%s として動作します。",
      desired_name,
      alternative_name
    ),
  }
end

return M
