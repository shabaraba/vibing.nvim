---/context command handler
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(args, chat_buffer)
  if #args == 0 then
    vim.notify("[vibing] Usage: /context <file_path>", vim.log.levels.WARN)
    return false
  end

  local file_path = args[1]

  -- ファイルパスを展開
  local expanded_path = vim.fn.expand(file_path)

  -- ファイルが存在するかチェック
  if vim.fn.filereadable(expanded_path) ~= 1 then
    vim.notify(
      string.format("[vibing] File not readable: %s", expanded_path),
      vim.log.levels.ERROR
    )
    return false
  end

  -- コンテキストに追加（notify()はcontext.add()内で実行される）
  require("vibing.context").add(expanded_path)

  -- チャットバッファのコンテキスト行を更新
  if chat_buffer and chat_buffer._update_context_line then
    chat_buffer:_update_context_line()
  end

  return true
end
