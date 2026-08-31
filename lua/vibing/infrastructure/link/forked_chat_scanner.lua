---@class Vibing.Infrastructure.Link.ForkedChatScanner : Vibing.Infrastructure.Link.Scanner
---フォークされたチャットファイルの forked_from フィールドを更新するスキャナー
local ForkedChatScanner = {}
ForkedChatScanner.__index = ForkedChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
setmetatable(ForkedChatScanner, { __index = Scanner })

---@return Vibing.Infrastructure.Link.ForkedChatScanner
function ForkedChatScanner.new()
  return setmetatable({}, ForkedChatScanner)
end

---@param base_dir string
---@return string[]
function ForkedChatScanner:find_target_files(base_dir)
  if vim.fn.isdirectory(base_dir) == 0 then
    return {}
  end

  -- Search for both .vibing and .md files (chat buffers use .md extension)
  local md_files = vim.fn.glob(base_dir .. "**/*.md", false, true)
  local vibing_files = vim.fn.glob(base_dir .. "**/*.vibing", false, true)

  return vim.list_extend(md_files, vibing_files)
end

---@param file_path string
---@param target_path string
---@return boolean
function ForkedChatScanner:contains_link(file_path, target_path)
  local ok, content = pcall(vim.fn.readfile, file_path)
  if not ok or not content or #content == 0 then
    return false
  end

  -- frontmatterからforked_fromを抽出
  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  local text = table.concat(content, "\n")
  local frontmatter = Frontmatter.parse(text)

  if not frontmatter or not frontmatter.forked_from then
    return false
  end

  -- forked_fromの正規化（Git相対パスまたはチルダ展開パス→絶対パス）
  local Git = require("vibing.core.utils.git")
  local forked_from_abs
  local git_root = Git.get_root()
  if git_root and not frontmatter.forked_from:match("^[/~]") then
    forked_from_abs = vim.fs.joinpath(git_root, frontmatter.forked_from)
  else
    forked_from_abs = vim.fn.fnamemodify(vim.fn.expand(frontmatter.forked_from), ":p")
  end

  local target_abs = vim.fn.fnamemodify(target_path, ":p")

  return forked_from_abs == target_abs
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function ForkedChatScanner:update_link(file_path, old_path, new_path)
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return false, string.format("Failed to read file: %s", lines or "unknown")
  end

  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  local Git = require("vibing.core.utils.git")

  local text = table.concat(lines, "\n")
  local frontmatter = Frontmatter.parse(text)

  if not frontmatter or not frontmatter.forked_from then
    return false, "No forked_from field"
  end

  local new_forked_from = Git.to_display_path(new_path)

  -- 開かれているバッファがあればそちら経由で書く。ディスクを直接書くと、そのバッファの
  -- 次の保存が同期した内容を巻き戻すか、確認プロンプトでNeovimを止める
  -- （infrastructure/storage/frontmatter_file.lua のコメント参照）
  local FrontmatterFile = require("vibing.infrastructure.storage.frontmatter_file")
  return FrontmatterFile.update(file_path, { forked_from = new_forked_from })
end

return ForkedChatScanner
