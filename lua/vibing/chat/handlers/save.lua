---/save command handler
---@param _ string[] args (unused)
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf then
    notify.error("No chat buffer to save")
    return false
  end

  -- バッファを保存
  local buf = chat_buffer.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Chat buffer is not valid")
    return false
  end

  -- :write コマンドを実行（エラーハンドリング）
  local ok, err = pcall(function()
    vim.cmd(string.format("buffer %d | write", buf))
  end)

  if not ok then
    notify.error(string.format("Failed to save: %s", err))
    return false
  end

  notify.info("Chat saved")

  return true
end
