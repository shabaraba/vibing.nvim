---/clear command handler
---@param _ string[] args (unused)
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(_, chat_buffer)
  -- コンテキストをクリア（notify()はcontext.clear()内で実行される）
  require("vibing.context").clear()

  -- チャットバッファのコンテキスト行を更新
  if chat_buffer and chat_buffer._update_context_line then
    chat_buffer:_update_context_line()
  end

  return true
end
