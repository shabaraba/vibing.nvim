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
  local data = Entity.to_frontmatter(squad)

  -- フィールド更新リスト
  local fields = {
    { "squad_name", data.squad_name },
    { "task_type", data.task_type },
  }

  -- task_ref が存在する場合は追加
  if data.task_ref then
    table.insert(fields, { "task_ref", data.task_ref })
  end

  -- 各フィールドを更新
  for _, field in ipairs(fields) do
    local ok = pcall(FrontmatterHandler.update_field, bufnr, field[1], field[2], false)
    if not ok then
      return false
    end
  end

  return true
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
