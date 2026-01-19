---@class Vibing.Domain.Squad.SquadRole
---分隊の役割を表す値オブジェクト
local M = {}

---役割の定数
M.COMMANDER = "commander"
M.SQUAD = "squad"

---SquadRole値オブジェクトを生成
---@param value "commander"|"squad" 役割の値
---@return table squad_role { value: string }
---@error 無効な役割の場合エラー
function M.new(value)
  if value ~= M.COMMANDER and value ~= M.SQUAD then
    error(string.format("Invalid squad role: %s", value))
  end

  return {
    value = value,
  }
end

---カレントディレクトリからSquad役割を判定
---worktree環境（.worktrees/配下）かどうかで判定
---@param cwd? string カレントディレクトリ（省略時はvim.fn.getcwd()）
---@return table squad_role SquadRole値オブジェクト
function M.determine_from_cwd(cwd)
  cwd = cwd or vim.fn.getcwd()

  -- worktree判定: .worktrees/ 配下かどうか
  local is_worktree = cwd:match("/.worktrees/") ~= nil

  if is_worktree then
    return M.new(M.SQUAD)
  else
    return M.new(M.COMMANDER)
  end
end

---2つのSquadRoleが等価かどうか判定
---@param a table SquadRole
---@param b table SquadRole
---@return boolean is_equal 等価な場合true
function M.equals(a, b)
  return a.value == b.value
end

return M
