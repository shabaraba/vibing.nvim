---@class Vibing.Domain.Squad.NamingService
---分隊名の割り当てビジネスロジックを集約
local M = {}

local SquadName = require("vibing.domain.squad.value_objects.squad_name")
local SquadRole = require("vibing.domain.squad.value_objects.squad_role")
local Entity = require("vibing.domain.squad.entity")

---新規チャット作成時のSquad名を決定
---@param context table { cwd?: string, task_ref?: string, bufnr: number }
---@param registry table SquadRegistry（衝突チェック用）
---@return table squad Squadエンティティ
function M.assign_squad_name(context, registry)
  -- 1. 役割判定（Commander or Squad）
  local role = SquadRole.determine_from_cwd(context.cwd)

  -- 2. Commander の場合は固定名
  if role.value == SquadRole.COMMANDER then
    return Entity.new({
      name = SquadName.COMMANDER,
      role = SquadRole.COMMANDER,
      bufnr = context.bufnr,
      task_ref = context.task_ref,
    })
  end

  -- 3. Squad の場合、未使用のNATO名を割り当て
  -- Phase 2: task_ref があれば既存割り当てを検索（将来拡張）
  local squad_name = M._find_available_name(registry)

  if not squad_name then
    error("All squad names are in use (26 squads limit)")
  end

  return Entity.new({
    name = squad_name,
    role = SquadRole.SQUAD,
    bufnr = context.bufnr,
    task_ref = context.task_ref,
  })
end

---未使用のSquad名を検索（内部関数）
---@param registry table SquadRegistry
---@return string? squad_name 次に使用可能な名前（全て使用中の場合nil）
function M._find_available_name(registry)
  return SquadName.get_next_available(registry.get_all_active())
end

return M
