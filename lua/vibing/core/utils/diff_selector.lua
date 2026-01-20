---@class Vibing.Utils.DiffSelector
---diff表示ツールの選択と実行を管理
local M = {}

---設定に基づいて適切なdiffツールを選択
---@param config Vibing.DiffConfig diff設定
---@return "git"|"mote" 使用するツール
function M.select_tool(config)
  if config.tool == "git" then
    return "git"
  end

  -- "mote" または "auto" の場合は可用性をチェック
  if config.tool == "mote" or config.tool == "auto" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    if MoteDiff.is_available() and MoteDiff.is_initialized(nil, config.mote.storage_dir) then
      return "mote"
    end
  end

  return "git"
end

---ファイルのdiffを表示（設定に基づいて適切なツールを選択）
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（moteのセッション別storage用、nilの場合はデフォルト）
function M.show_diff(file_path, session_id)
  local config = require("vibing.config").get()
  local tool = M.select_tool(config.diff)

  if tool == "mote" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    local mote_config = vim.deepcopy(config.diff.mote)

    -- セッションIDが指定されている場合はセッション専用storageを使用
    if session_id then
      mote_config.storage_dir = string.format(".vibing/mote/%s", session_id)
    end

    MoteDiff.show_diff(file_path, mote_config)
  else
    local GitDiff = require("vibing.core.utils.git_diff")
    GitDiff.show_diff(file_path)
  end
end

return M
