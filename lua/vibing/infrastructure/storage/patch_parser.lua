---@class Vibing.Infrastructure.PatchParser
---パッチファイルを解析してファイルリストを抽出
local M = {}

local PatchStorage = require("vibing.infrastructure.storage.patch_storage")

---@param session_id string セッションID
---@param patch_filename string パッチファイル名
---@return string[] ファイルパスのリスト
function M.extract_file_list(session_id, patch_filename)
  if not session_id or not patch_filename then
    return {}
  end

  -- PatchStorage.read()でパッチ内容を読み込む
  local patch_content = PatchStorage.read(session_id, patch_filename)
  if not patch_content then
    return {}
  end

  local files = {}
  local seen = {}

  -- 行ごとに処理
  for line in patch_content:gmatch("[^\r\n]+") do
    -- git diff形式: "diff --git a/path/to/file b/path/to/file"
    local file_path = line:match("^diff %-%-git a/(.+) b/")
    if file_path then
      -- 重複を避ける
      if not seen[file_path] then
        seen[file_path] = true
        table.insert(files, file_path)
      end
    end
  end

  return files
end

return M
