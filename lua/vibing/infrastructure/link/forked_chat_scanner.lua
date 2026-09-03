---@class Vibing.Infrastructure.Link.ForkedChatScanner : Vibing.Infrastructure.Link.Scanner
---@field field string 追従させる frontmatter のキー
---チャットのパスを1つだけ持つ frontmatter フィールドを、リネームに追従させるスキャナー。
---
---名前は最初の用途（fork の `forked_from`）から来ているが、`:VibingChatHandoff` が書く
---`continued_from` も同じ形（スカラー1つ、表示パス）なので、キー名を差し替えて使い回す。
---リスト型（`orchestrated*`）は要素単位で書き換える必要があるので `OrchestrationChatScanner`。
local ForkedChatScanner = {}
ForkedChatScanner.__index = ForkedChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
local FrontmatterFile = require("vibing.infrastructure.storage.frontmatter_file")
local Git = require("vibing.core.utils.git")

setmetatable(ForkedChatScanner, { __index = Scanner })

---@param field string? 追従させるキー（省略時 `forked_from`）
---@return Vibing.Infrastructure.Link.ForkedChatScanner
function ForkedChatScanner.new(field)
  return setmetatable({ field = field or "forked_from" }, ForkedChatScanner)
end

---@param file_path string
---@param target_path string
---@return boolean
function ForkedChatScanner:contains_link(file_path, target_path)
  local frontmatter = self:read_frontmatter(file_path)
  if not frontmatter or type(frontmatter[self.field]) ~= "string" then
    return false
  end

  return Git.from_display_path(frontmatter[self.field], self:git_root())
    == vim.fn.fnamemodify(target_path, ":p")
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function ForkedChatScanner:update_link(file_path, old_path, new_path)
  -- `SyncManager` 経由なら `contains_link` が直前に確認しているが、単独で呼ばれたときに
  -- キーを持たないファイルへキーを**新設**してしまうので、ここでも確かめる
  local frontmatter = self:read_frontmatter(file_path)
  if not frontmatter or not frontmatter[self.field] then
    return false, "No " .. self.field .. " field"
  end

  -- 開かれているバッファがあればそちら経由で書く。ディスクを直接書くと、そのバッファの
  -- 次の保存が同期した内容を巻き戻すか、確認プロンプトでNeovimを止める
  -- （infrastructure/storage/frontmatter_file.lua のコメント参照）
  return FrontmatterFile.update(file_path, { [self.field] = Git.to_display_path(new_path) })
end

return ForkedChatScanner
