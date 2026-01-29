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

  -- すべての.vibingファイルを検索
  return vim.fn.glob(base_dir .. "**/*.vibing", false, true)
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

  -- forked_fromの正規化（Git相対パスまたはチルダ展開パス）
  local Git = require("vibing.core.utils.git")
  local forked_from_abs = Git.resolve_path(frontmatter.forked_from)
  if not forked_from_abs then
    -- チルダ展開パスの場合
    forked_from_abs = vim.fn.expand(frontmatter.forked_from)
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

  -- frontmatterを更新
  local updated_text = Frontmatter.update(text, { forked_from = new_forked_from })
  local updated_lines = vim.split(updated_text, "\n", { plain = true })

  local result = vim.fn.writefile(updated_lines, file_path)
  if result ~= 0 then
    return false, string.format("Failed to write file: %s", vim.v.errmsg or "unknown")
  end

  return true, nil
end

return ForkedChatScanner
