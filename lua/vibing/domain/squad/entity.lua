---@class Vibing.Domain.Squad.Entity
---分隊の集約ルート（Aggregate Root）
---分隊名、役割、バッファ番号などの情報を保持
local M = {}

local SquadName = require("vibing.domain.squad.value_objects.squad_name")
local SquadRole = require("vibing.domain.squad.value_objects.squad_role")

---Squadエンティティを生成
---@param params table { name: string, role: string, bufnr: number, task_ref?: string, created_at?: string }
---@return table squad Squadエンティティ
function M.new(params)
  -- 値オブジェクトの生成（検証を含む）
  local name = SquadName.new(params.name)
  local role = SquadRole.new(params.role)

  return {
    -- 一意識別子（バッファ番号ベース）
    id = tostring(params.bufnr),

    -- 分隊名（値オブジェクト）
    name = name,

    -- 役割（値オブジェクト）
    role = role,

    -- 関連付けられたバッファ番号
    bufnr = params.bufnr,

    -- タスク参照（オプション、Phase 2で使用）
    task_ref = params.task_ref or nil,

    -- 作成日時
    created_at = params.created_at or os.date("%Y-%m-%dT%H:%M:%S"),

    -- オリジナルの分隊名（衝突時に一時変更された場合の元の名前）
    original_name = params.original_name or params.name,
  }
end

---Squadエンティティをfrontmatter用のテーブルに変換
---@param squad table Squadエンティティ
---@return table frontmatter_data { squad_name: string, task_ref?: string }
function M.to_frontmatter(squad)
  return {
    squad_name = squad.name.value,
    task_ref = squad.task_ref,
  }
end

---FrontmatterからSquad情報を読み込んでエンティティ化
---@param frontmatter table Frontmatterデータ
---@param bufnr number バッファ番号
---@return table? squad Squadエンティティ（squad_nameがない場合nil）
function M.from_frontmatter(frontmatter, bufnr)
  if not frontmatter.squad_name then
    return nil
  end

  -- task_ref から role を推測（worktree パスがあれば squad、なければ commander）
  local role = SquadRole.SQUAD
  if not frontmatter.task_ref or frontmatter.task_ref == "" then
    role = SquadRole.COMMANDER
  end

  return M.new({
    name = frontmatter.squad_name,
    role = role,
    bufnr = bufnr,
    task_ref = frontmatter.task_ref,
    created_at = frontmatter.created_at,
  })
end

---分隊名が衝突時に一時変更されたかどうか判定
---@param squad table Squadエンティティ
---@return boolean has_collision 衝突があればtrue
function M.has_name_collision(squad)
  return squad.name.value ~= squad.original_name
end

return M
