---/save command handler
---@param _ string[] args (unused)
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf then
    vim.notify("[vibing] No chat buffer to save", vim.log.levels.ERROR)
    return false
  end

  -- バッファを保存
  local buf = chat_buffer.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("[vibing] Chat buffer is not valid", vim.log.levels.ERROR)
    return false
  end

  -- :write コマンドを実行（エラーハンドリング）
  local ok, err = pcall(function()
    vim.cmd(string.format("buffer %d | write", buf))
  end)

  if not ok then
    vim.notify(
      string.format("[vibing] Failed to save: %s", err),
      vim.log.levels.ERROR
    )
    return false
  end

  vim.notify("[vibing] Chat saved", vim.log.levels.INFO)

  return true
end
