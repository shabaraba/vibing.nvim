---@class Vibing.Utils.DiffSelector
---mote diffの表示を管理
local M = {}

---ファイルのdiffを表示（moteを使用）
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
function M.show_diff(file_path, session_id, cwd)
  local config = require("vibing.config").get()
  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.mote)

  -- mote v0.2.0: --project/--context APIを使用
  mote_config.project = mote_config.project or MoteDiff.get_project_name()
  local context_prefix = mote_config.context_prefix or "vibing"
  mote_config.context = MoteDiff.build_context_name(context_prefix, cwd)

  -- Normalize cwd to absolute path
  if cwd then
    mote_config.cwd = vim.fn.fnamemodify(cwd, ":p")
  end

  MoteDiff.show_diff(file_path, mote_config)
end

return M
