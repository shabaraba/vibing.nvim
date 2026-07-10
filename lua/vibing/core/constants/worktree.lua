---@class Vibing.Core.WorktreeConstants
---git worktreeの配置規約に関する定数定義
local M = {}

---worktreeを配置するディレクトリ（gitルートからの相対パス、末尾スラッシュ付き）
---@type string
M.DIR = ".vibing/worktrees/"

---M.DIR配下のcwdからブランチ名を抽出するLuaパターン
---@type string
M.PATTERN = "%.vibing/worktrees/([^/]+)"

---cwdがworktree配下かどうかを判定し、ブランチ名を抽出する
---@param cwd string|nil 作業ディレクトリ
---@return string|nil branch_name worktree配下でなければnil
function M.match_branch(cwd)
  if not cwd then
    return nil
  end
  return cwd:match(M.PATTERN)
end

return M
