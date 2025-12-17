---/clearコマンドハンドラー
---チャット内で/clearを実行した際に呼び出される
---手動で追加されたコンテキストファイルをすべて削除
---自動コンテキスト（開いているバッファ）は設定に従い継続
---コンテキストクリア後、チャットバッファのコンテキスト表示行を更新
---@param _ string[] コマンド引数（このハンドラーでは未使用）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 常にtrueを返す（コマンド実行成功）
return function(_, chat_buffer)
  -- コンテキストをクリア（notify()はcontext.clear()内で実行される）
  require("vibing.context").clear()

  -- チャットバッファのコンテキスト行を更新
  if chat_buffer and chat_buffer._update_context_line then
    chat_buffer:_update_context_line()
  end

  return true
end
