---@class Vibing.Infrastructure.Squad.FrontmatterRepository
---YAMLフロントマターへのSquad情報永続化
---ISquadRepositoryインターフェースの具象実装
local M = {}

local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local Entity = require("vibing.domain.squad.entity")

---Squadエンティティをfrontmatterに保存
---@param squad table Squadエンティティ
---@param bufnr number バッファ番号
---@return boolean success 成功した場合true
function M.save(squad, bufnr)
  local frontmatter_data = Entity.to_frontmatter(squad)

  -- squad_name フィールドを更新
  local ok1 = pcall(
    FrontmatterHandler.update_field,
    bufnr,
    "squad_name",
    frontmatter_data.squad_name,
    false -- update_timestamp = false
  )

  -- task_type フィールドを更新
  local ok2 = pcall(
    FrontmatterHandler.update_field,
    bufnr,
    "task_type",
    frontmatter_data.task_type,
    false
  )

  -- task_ref フィールドを更新（オプション）
  local ok3 = true
  if frontmatter_data.task_ref then
    ok3 = pcall(
      FrontmatterHandler.update_field,
      bufnr,
      "task_ref",
      frontmatter_data.task_ref,
      false
    )
  end

  return ok1 and ok2 and ok3
end

---バッファからSquadエンティティを読み込み
---@param bufnr number バッファ番号
---@return table? squad Squadエンティティ（squad_nameがない場合nil）
function M.load(bufnr)
  local ok, frontmatter = pcall(FrontmatterHandler.parse, bufnr)

  if not ok or not frontmatter then
    return nil
  end

  return Entity.from_frontmatter(frontmatter, bufnr)
end

return M
