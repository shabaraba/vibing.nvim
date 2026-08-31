---@class Vibing.Infrastructure.Link.ForkedChatScanner : Vibing.Infrastructure.Link.Scanner
---フォークされたチャットファイルの forked_from フィールドを更新するスキャナー
local ForkedChatScanner = {}
ForkedChatScanner.__index = ForkedChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
local FrontmatterFile = require("vibing.infrastructure.storage.frontmatter_file")
local Git = require("vibing.core.utils.git")

setmetatable(ForkedChatScanner, { __index = Scanner })

---@return Vibing.Infrastructure.Link.ForkedChatScanner
function ForkedChatScanner.new()
  return setmetatable({}, ForkedChatScanner)
end

---@param file_path string
---@param target_path string
---@return boolean
function ForkedChatScanner:contains_link(file_path, target_path)
  local frontmatter = self:read_frontmatter(file_path)
  if not frontmatter or type(frontmatter.forked_from) ~= "string" then
    return false
  end

  return Git.from_display_path(frontmatter.forked_from, self:git_root())
    == vim.fn.fnamemodify(target_path, ":p")
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function ForkedChatScanner:update_link(file_path, old_path, new_path)
  -- `SyncManager` 経由なら `contains_link` が直前に確認しているが、単独で呼ばれたときに
  -- `forked_from` を持たないファイルへキーを**新設**してしまうので、ここでも確かめる
  local frontmatter = self:read_frontmatter(file_path)
  if not frontmatter or not frontmatter.forked_from then
    return false, "No forked_from field"
  end

  -- 開かれているバッファがあればそちら経由で書く。ディスクを直接書くと、そのバッファの
  -- 次の保存が同期した内容を巻き戻すか、確認プロンプトでNeovimを止める
  -- （infrastructure/storage/frontmatter_file.lua のコメント参照）
  return FrontmatterFile.update(file_path, { forked_from = Git.to_display_path(new_path) })
end

return ForkedChatScanner
