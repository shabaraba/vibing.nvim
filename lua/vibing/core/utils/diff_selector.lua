---@class Vibing.Utils.DiffSelector
---diff表示ツールの選択と実行を管理
local M = {}

---設定に基づいて適切なdiffツールを選択
---@param config Vibing.DiffConfig diff設定
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return "git"|"mote" 使用するツール
function M.select_tool(config, session_id, cwd)
  if config.tool == "git" then
    return "git"
  end

  if config.tool == "mote" or config.tool == "auto" then
    local MoteDiff = require("vibing.core.utils.mote_diff")

    -- mote v0.2.0: --project/--context APIを使用
    local project = config.mote.project or MoteDiff.get_project_name()
    local context_prefix = config.mote.context_prefix or "vibing"
    local context = MoteDiff.build_context_name(context_prefix, cwd)

    if MoteDiff.is_available() and MoteDiff.is_initialized(project, context) then
      return "mote"
    end
  end

  return "git"
end

---ファイルのdiffを表示（設定に基づいて適切なツールを選択）
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
function M.show_diff(file_path, session_id, cwd)
  local config = require("vibing.config").get()
  local tool = M.select_tool(config.diff, session_id, cwd)

  if tool == "mote" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local mote_config = vim.deepcopy(config.diff.mote)

    -- mote v0.2.0: --project/--context APIを使用
    mote_config.project = mote_config.project or MoteDiff.get_project_name()
    local context_prefix = mote_config.context_prefix or "vibing"
    mote_config.context = MoteDiff.build_context_name(context_prefix, cwd)

    -- Normalize cwd to absolute path
    if cwd then
      mote_config.cwd = vim.fn.fnamemodify(cwd, ":p")
    end

    MoteDiff.show_diff(file_path, mote_config)
  else
    local GitDiff = require("vibing.core.utils.git_diff")
    GitDiff.show_diff(file_path)
  end
end

return M
