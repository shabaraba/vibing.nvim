---@class Vibing.Presentation.Chat.DeletionController
local M = {}

local ChatDeletionPicker = require("vibing.ui.chat_deletion_picker")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local DeleteChatsUseCase = require("vibing.application.chat.use_cases.delete_chats")
local notify = require("vibing.core.utils.notify")

---@param opts table
---@param config table
function M.handle_delete_command(opts, config)
  local args = opts.args or ""
  local unrenamed_only = args:match("%-%-unrenamed") ~= nil
  local save_dir = FileManager.get_save_directory(config)

  if unrenamed_only then
    DeleteChatsUseCase.delete_unrenamed(save_dir, config, function(success, message)
      if success then
        notify.info(message)
      else
        notify.error(message)
      end
    end)
  else
    ChatDeletionPicker.show(save_dir, config, false)
  end
end

return M
