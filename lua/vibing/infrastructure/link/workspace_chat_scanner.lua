---@class Vibing.Infrastructure.Link.WorkspaceChatScanner : Vibing.Infrastructure.Link.Scanner
---meta.yamlのchat_files配列を、チャットファイルリネーム時に同期するスキャナー
local WorkspaceChatScanner = {}
WorkspaceChatScanner.__index = WorkspaceChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
setmetatable(WorkspaceChatScanner, { __index = Scanner })

local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")

---@return Vibing.Infrastructure.Link.WorkspaceChatScanner
function WorkspaceChatScanner.new()
  return setmetatable({}, WorkspaceChatScanner)
end

---@param base_dir string
---@return string[]
function WorkspaceChatScanner:find_target_files(base_dir)
  if vim.fn.isdirectory(base_dir) == 0 then
    return {}
  end
  return vim.fn.glob(base_dir .. "**/meta.yaml", false, true)
end

---@param target_path string
---@return string
local function to_relative(target_path)
  return Git.to_display_path(target_path)
end

---@param file_path string
---@param target_path string
---@return boolean
function WorkspaceChatScanner:contains_link(file_path, target_path)
  local data = Meta.read(file_path)
  if not data or not data.chat_files then
    return false
  end

  local target_relative = to_relative(target_path)
  for _, chat_file in ipairs(data.chat_files) do
    if chat_file == target_relative or chat_file == target_path then
      return true
    end
  end
  return false
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function WorkspaceChatScanner:update_link(file_path, old_path, new_path)
  local old_relative = to_relative(old_path)
  local new_relative = to_relative(new_path)

  local ok, err = Meta.replace_chat_file(file_path, old_relative, new_relative)
  if ok then
    return true, nil
  end

  -- Fall back to matching the raw (non-relative) path, e.g. when Git root is unavailable
  return Meta.replace_chat_file(file_path, old_path, new_path)
end

return WorkspaceChatScanner
