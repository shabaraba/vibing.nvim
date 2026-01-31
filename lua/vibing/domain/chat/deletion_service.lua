---@class Vibing.Domain.Chat.DeletionService
---チャット削除のドメインサービス
---削除対象のフィルタリング、削除実行の検証を担当
local M = {}

---@param entities Vibing.Domain.Chat.FileEntity[]
---@return Vibing.Domain.Chat.FileEntity[]
function M.filter_unrenamed(entities)
  local result = {}
  for _, entity in ipairs(entities) do
    if not entity:is_renamed_file() then
      table.insert(result, entity)
    end
  end
  return result
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@return boolean valid
---@return string? error_message
function M.validate_deletion(entities)
  if not entities or #entities == 0 then
    return false, "No files selected for deletion"
  end

  for _, entity in ipairs(entities) do
    if vim.fn.filereadable(entity.path) ~= 1 then
      return false, string.format("File not found: %s", entity.path)
    end
  end

  return true, nil
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@return table {count: number, total_size: number, renamed_count: number, unrenamed_count: number}
function M.generate_deletion_stats(entities)
  local stats = {
    count = #entities,
    total_size = 0,
    renamed_count = 0,
    unrenamed_count = 0,
  }

  for _, entity in ipairs(entities) do
    stats.total_size = stats.total_size + (entity.size or 0)
    if entity:is_renamed_file() then
      stats.renamed_count = stats.renamed_count + 1
    else
      stats.unrenamed_count = stats.unrenamed_count + 1
    end
  end

  return stats
end

---@param stats table
---@return string[]
function M.build_confirmation_message(stats)
  local lines = {
    string.format("Delete %d chat file(s)?", stats.count),
  }

  if stats.renamed_count > 0 then
    table.insert(lines, string.format("  - Renamed: %d", stats.renamed_count))
  end
  if stats.unrenamed_count > 0 then
    table.insert(lines, string.format("  - Unrenamed: %d", stats.unrenamed_count))
  end

  local size_kb = stats.total_size / 1024
  if size_kb < 1024 then
    table.insert(lines, string.format("  - Total size: %.1f KB", size_kb))
  else
    table.insert(lines, string.format("  - Total size: %.1f MB", size_kb / 1024))
  end

  table.insert(lines, "")
  table.insert(lines, "This action cannot be undone.")

  return lines
end

return M
