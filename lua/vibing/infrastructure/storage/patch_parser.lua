---@class Vibing.Infrastructure.PatchParser
---パッチファイルを解析してファイルリストを抽出
local M = {}

local PatchStorage = require("vibing.infrastructure.storage.patch_storage")

-- Git diff format pattern: "diff --git a/path/to/file b/path/to/file"
local DIFF_HEADER_PATTERN = "^diff %-%-git a/(.+) b/"

---@param session_id string セッションID
---@param patch_filename string パッチファイル名
---@return string[] ファイルパスのリスト
function M.extract_file_list(session_id, patch_filename)
  if not session_id or not patch_filename then
    return {}
  end

  local patch_content = PatchStorage.read(session_id, patch_filename)
  if not patch_content then
    return {}
  end

  local files = {}
  local seen = {}

  for line in patch_content:gmatch("[^\r\n]+") do
    local file_path = line:match(DIFF_HEADER_PATTERN)
    if file_path and not seen[file_path] then
      seen[file_path] = true
      table.insert(files, file_path)
    end
  end

  return files
end

return M
