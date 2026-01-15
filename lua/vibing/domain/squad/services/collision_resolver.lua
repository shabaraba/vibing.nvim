---@class Vibing.Domain.Squad.CollisionResolver
---分隊名の衝突解決ロジック
local M = {}

local SquadName = require("vibing.domain.squad.value_objects.squad_name")

---分隊名の衝突を検出し、代替名を提案
---@param desired_name string 希望する分隊名
---@param registry table SquadRegistry
---@return table resolution { has_collision: boolean, alternative_name?: string, notice_message?: string }
function M.resolve_collision(desired_name, registry)
  if registry.is_available(desired_name) then
    return { has_collision = false }
  end

  local alternative_name = SquadName.get_next_available(registry.get_all_active())

  if not alternative_name then
    return {
      has_collision = true,
      alternative_name = nil,
      notice_message = string.format(
        "Squad name %s is already in use and no alternative is available (26 squad limit).",
        desired_name
      ),
    }
  end

  return {
    has_collision = true,
    alternative_name = alternative_name,
    notice_message = string.format(
      "Squad name %s is already in use, operating as %s.",
      desired_name,
      alternative_name
    ),
  }
end

return M
