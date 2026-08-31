---@class Vibing.Application.Chat.UseCases.DeleteChats
local M = {}

local ChatRepository = require("vibing.infrastructure.storage.chat_repository")
local DeletionService = require("vibing.domain.chat.deletion_service")
local ConfirmationDialog = require("vibing.ui.confirmation_dialog")

---@param save_dir string
---@return Vibing.Domain.Chat.FileEntity[]
function M.list_all_files(save_dir)
  return ChatRepository.find_all(save_dir)
end

---@param save_dir string
---@return Vibing.Domain.Chat.FileEntity[]
function M.list_unrenamed_files(save_dir)
  local all_files = ChatRepository.find_all(save_dir)
  return DeletionService.filter_unrenamed(all_files)
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@param config table
---@param on_complete fun(success: boolean, message: string)
function M.delete_selected(entities, config, on_complete)
  local valid, error_msg = DeletionService.validate_deletion(entities)
  if not valid then
    on_complete(false, error_msg)
    return
  end

  local stats = DeletionService.generate_deletion_stats(entities)
  local confirmation_lines = DeletionService.build_confirmation_message(stats)

  ConfirmationDialog.show({
    title = "Confirm Deletion",
    lines = confirmation_lines,
    on_confirm = function()
      M._execute_deletion(entities, config, on_complete)
    end,
    on_cancel = function()
      on_complete(false, "Deletion canceled by user")
    end,
  })
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@param _config table
---@param on_complete fun(success: boolean, message: string)
function M._execute_deletion(entities, _config, on_complete)
  local delete_result = ChatRepository.delete_batch(entities)

  local message =
    M._build_result_message(delete_result.success_count, delete_result.failed_count, delete_result.errors)
  on_complete(delete_result.failed_count == 0, message)
end

---@param success_count number
---@param failed_count number
---@param errors string[]
---@param success_label string|nil defaults to "Deleted"
---@return string
function M._build_result_message(success_count, failed_count, errors, success_label)
  success_label = success_label or "Deleted"
  local parts = {}

  if success_count > 0 then
    table.insert(parts, string.format("%s %d file(s)", success_label, success_count))
  end

  if failed_count > 0 then
    local error_summary
    if #errors > 3 then
      error_summary = table.concat(vim.list_slice(errors, 1, 3), ", ")
        .. string.format(" (and %d more)", #errors - 3)
    else
      error_summary = table.concat(errors, ", ")
    end
    table.insert(parts, string.format("Failed to delete %d file(s): %s", failed_count, error_summary))
  end

  return table.concat(parts, ". ")
end

---@param save_dir string
---@param config table
---@param on_complete fun(success: boolean, message: string)
function M.delete_unrenamed(save_dir, config, on_complete)
  local unrenamed = M.list_unrenamed_files(save_dir)

  if #unrenamed == 0 then
    on_complete(true, "No unrenamed files found")
    return
  end

  M.delete_selected(unrenamed, config, on_complete)
end

return M
