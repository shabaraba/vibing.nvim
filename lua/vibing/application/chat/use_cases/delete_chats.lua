---@class Vibing.Application.Chat.UseCases.DeleteChats
local M = {}

local ChatRepository = require("vibing.infrastructure.storage.chat_repository")
local MoteCleaner = require("vibing.infrastructure.storage.mote_cleaner")
local DeletionService = require("vibing.domain.chat.deletion_service")
local MoteContext = require("vibing.core.utils.mote.context")
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
---@param config table
---@param on_complete fun(success: boolean, message: string)
function M._execute_deletion(entities, config, on_complete)
  local mote_config = {
    project = (config.diff and config.diff.mote and config.diff.mote.project) or vim.fn.fnamemodify(vim.fn.getcwd(), ":t"),
    context = MoteContext.build_name(nil),
    cwd = vim.fn.getcwd(),
  }

  MoteCleaner.clean_batch(entities, mote_config, function(_, mote_failed, mote_errors)
    local delete_result = ChatRepository.delete_batch(entities)

    local total_success = delete_result.success_count
    local total_failed = delete_result.failed_count + mote_failed
    local all_errors = vim.list_extend(delete_result.errors, mote_errors)

    local message = M._build_result_message(total_success, total_failed, all_errors)
    on_complete(total_failed == 0, message)
  end)
end

---@param success_count number
---@param failed_count number
---@param errors string[]
---@return string
function M._build_result_message(success_count, failed_count, errors)
  local parts = {}

  if success_count > 0 then
    table.insert(parts, string.format("Deleted %d file(s)", success_count))
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
