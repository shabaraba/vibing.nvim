---@class Vibing.Utils.DiffSelector
---diff表示ツールの選択と実行を管理
local M = {}

---設定に基づいて適切なdiffツールを選択
---@param config Vibing.DiffConfig diff設定
---@return "git"|"mote" 使用するツール
function M.select_tool(config)
  if config.tool == "git" then
    return "git"
  elseif config.tool == "mote" then
    return "mote"
  elseif config.tool == "auto" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    if MoteDiff.is_available() and MoteDiff.is_initialized() then
      return "mote"
    else
      return "git"
    end
  end
  return "git"
end

---ファイルのdiffを表示（設定に基づいて適切なツールを選択）
---@param file_path string ファイルパス（絶対パス）
function M.show_diff(file_path)
  local config = require("vibing.config").get()
  local tool = M.select_tool(config.diff)

  if tool == "mote" then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    MoteDiff.show_diff(file_path, config.diff.mote)
  else
    local GitDiff = require("vibing.core.utils.git_diff")
    GitDiff.show_diff(file_path)
  end
end

return M
