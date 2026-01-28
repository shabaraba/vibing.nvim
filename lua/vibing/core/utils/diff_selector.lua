---@class Vibing.Utils.DiffSelector
---diff表示ツールの選択と実行を管理
local M = {}

---設定に基づいて適切なdiffツールを選択
---@param config Vibing.DiffConfig diff設定
---@param session_id? string セッションID（セッション固有のstorage_dirをチェックする場合に指定）
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return "git"|"mote" 使用するツール
function M.select_tool(config, session_id, cwd)
  if config.tool == "git" then
    return "git"
  end

  if config.tool == "mote" or config.tool == "auto" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local storage_dir = MoteDiff.build_session_storage_dir(config.mote.storage_dir, cwd)

    if MoteDiff.is_available() and MoteDiff.is_initialized(nil, storage_dir) then
      return "mote"
    end
  end

  return "git"
end

---ファイルのdiffを表示（設定に基づいて適切なツールを選択）
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（moteのセッション別storage用）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
function M.show_diff(file_path, session_id, cwd)
  local config = require("vibing.config").get()
  local tool = M.select_tool(config.diff, session_id, cwd)

  if tool == "mote" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local mote_config = vim.deepcopy(config.diff.mote)

    -- Build worktree-specific storage_dir (returns relative path)
    local relative_storage_dir = MoteDiff.build_session_storage_dir(mote_config.storage_dir, cwd)

    -- Convert to absolute path from git root
    local Git = require("vibing.core.utils.git")
    local git_root = Git.get_root()
    mote_config.storage_dir = git_root and vim.fn.fnamemodify(git_root .. "/" .. relative_storage_dir, ":p")
      or vim.fn.fnamemodify(relative_storage_dir, ":p")

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
