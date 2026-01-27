---@class Vibing.Utils.DiffSelector
---diff表示ツールの選択と実行を管理
local M = {}

---設定に基づいて適切なdiffツールを選択
---@param config Vibing.DiffConfig diff設定
---@param session_id? string セッションID（セッション固有のcontext_dirをチェックする場合に指定）
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return "git"|"mote" 使用するツール
function M.select_tool(config, session_id, cwd)
  if config.tool == "git" then
    return "git"
  end

  if config.tool == "mote" or config.tool == "auto" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local context_dir = MoteDiff.build_session_context_dir(config.mote.context_dir, session_id, cwd)

    if MoteDiff.is_available() and MoteDiff.is_initialized(nil, context_dir) then
      return "mote"
    end
  end

  return "git"
end

---ファイルのdiffを表示（設定に基づいて適切なツールを選択）
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（moteのセッション別context用）
---@param cwd? string 作業ディレクトリ（frontmatterのworking_dirから算出、worktree判定用）
function M.show_diff(file_path, session_id, cwd)
  local config = require("vibing.config").get()
  local tool = M.select_tool(config.diff, session_id, cwd)

  if tool == "mote" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local mote_config = vim.deepcopy(config.diff.mote)
    mote_config.context_dir = MoteDiff.build_session_context_dir(mote_config.context_dir, session_id, cwd)
    mote_config.cwd = cwd
    MoteDiff.show_diff(file_path, mote_config)
  else
    local GitDiff = require("vibing.core.utils.git_diff")
    GitDiff.show_diff(file_path)
  end
end

return M
