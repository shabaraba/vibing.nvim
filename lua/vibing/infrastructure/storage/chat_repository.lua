---@class Vibing.Infrastructure.Storage.ChatRepository
---チャットファイルのリポジトリ（永続化層）
---ファイルシステムからのチャットファイル検索・削除を担当
local M = {}

local FileEntity = require("vibing.domain.chat.file_entity")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@param save_dir string
---@return Vibing.Domain.Chat.FileEntity[]
function M.find_all(save_dir)
  local entities = {}

  if vim.fn.isdirectory(save_dir) ~= 1 then
    return entities
  end

  local normalized_dir = vim.fn.fnamemodify(save_dir, ":p")

  local function scan_dir(dir)
    local handle = vim.loop.fs_scandir(dir)
    if not handle then
      return
    end

    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      local path = dir .. "/" .. name

      if type == "directory" then
        scan_dir(path)
      elseif type == "file" and name:match("%.md$") then
        -- フロントマターでvibing.nvimチャットファイルかどうかを判定
        if Frontmatter.is_vibing_chat_file(path) then
          local entity = FileEntity.new(path)
          if entity then
            table.insert(entities, entity)
          end
        end
      end
    end
  end

  scan_dir(normalized_dir)
  return entities
end

---@param file_path string
---@return boolean success
---@return string? error_message
function M.delete_file(file_path)
  local ok, result = pcall(vim.fn.delete, file_path)
  if not ok or result ~= 0 then
    return false, string.format("Failed to delete file: %s", file_path)
  end
  return true, nil
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@return table {success_count: number, failed_count: number, errors: string[]}
function M.delete_batch(entities)
  local result = {
    success_count = 0,
    failed_count = 0,
    errors = {},
  }

  for _, entity in ipairs(entities) do
    local success, err = M.delete_file(entity.path)
    if success then
      result.success_count = result.success_count + 1
    else
      result.failed_count = result.failed_count + 1
      table.insert(result.errors, err or "Unknown error")
    end
  end

  return result
end

return M
