---@class Vibing.Infrastructure.GitBlobStorage
---Git blobを使用したファイル内容の永続化
local M = {}

local Git = require("vibing.core.utils.git")

---ファイル内容をGit blobとして保存
---@param content string[] ファイル内容（行の配列）
---@return string? sha 保存されたblobのSHA（失敗時はnil）
function M.store(content)
  return Git.store_blob(content)
end

---Git blobからファイル内容を読み込み
---@param sha string blobのSHA
---@return string[]? content ファイル内容（行の配列、失敗時はnil）
function M.read(sha)
  return Git.read_blob(sha)
end

---複数のファイル内容をGit blobとして保存
---@param saved_contents table<string, string[]> パスとファイル内容のマッピング
---@return table<string, string> saved_hashes パスとSHAのマッピング
function M.store_all(saved_contents)
  if not Git.is_git_repo() then
    return {}
  end

  local saved_hashes = {}
  for path, content in pairs(saved_contents) do
    local sha = M.store(content)
    if sha then
      saved_hashes[path] = sha
    end
  end
  return saved_hashes
end

---複数のGit blobからファイル内容を復元
---@param saved_hashes table<string, string> パスとSHAのマッピング
---@return table<string, string[]> saved_contents パスとファイル内容のマッピング
function M.restore_all(saved_hashes)
  if not Git.is_git_repo() then
    return {}
  end

  local saved_contents = {}
  for path, sha in pairs(saved_hashes) do
    local content = M.read(sha)
    if content then
      saved_contents[path] = content
    end
  end
  return saved_contents
end

---Git リポジトリかどうかをチェック
---@return boolean
function M.is_available()
  return Git.is_git_repo()
end

return M
