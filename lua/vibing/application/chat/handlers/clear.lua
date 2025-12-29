---@param _ string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(_, chat_buffer)
  require("vibing.context").clear()

  if chat_buffer and chat_buffer._update_context_line then
    chat_buffer:_update_context_line()
  end

  return true
end
