local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/context <file_path>", "Usage")
    return false
  end

  local file_path = args[1]

  local expanded_path = vim.fn.expand(file_path)

  if vim.fn.filereadable(expanded_path) ~= 1 then
    notify.error(string.format("File not readable: %s", expanded_path))
    return false
  end

  require("vibing.context").add(expanded_path)

  if chat_buffer and chat_buffer._update_context_line then
    chat_buffer:_update_context_line()
  end

  return true
end
