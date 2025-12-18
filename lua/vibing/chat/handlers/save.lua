local notify = require("vibing.utils.notify")

---/saveコマンドハンドラー
---チャット内で/saveを実行した際に呼び出される
---チャットバッファの内容をファイルに保存（YAMLフロントマター+Markdown本文）
---バッファの有効性チェックとエラーハンドリングを実施
---保存成功時には通知を表示
---@param _ string[] コマンド引数（このハンドラーでは未使用）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 保存に成功した場合true、バッファ無効や書き込みエラーの場合false
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
