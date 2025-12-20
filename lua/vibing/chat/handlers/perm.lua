local notify = require("vibing.utils.notify")

---@param args string[] コマンド引数
---@param chat_buffer Vibing.ChatBuffer チャットバッファ
---@return boolean 成功した場合true
return function(args, chat_buffer)
  if #args > 0 then
    notify.warn("The /perm command does not take arguments. Use it without arguments to open the permission builder.", "Permission")
    return false
  end

  -- Permission pickerを表示
  local permission_picker = require("vibing.ui.permission_picker")
  permission_picker.show(chat_buffer)

  return true
end
