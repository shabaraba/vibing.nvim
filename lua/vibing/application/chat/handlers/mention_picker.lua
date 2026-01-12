---/mention-picker コマンドハンドラ
---セッションピッカーを表示してメンションを送る
---@param args string コマンド引数（未使用）
---@param chat_buffer Vibing.ChatBuffer チャットバッファインスタンス
---@return boolean handled コマンドが処理されたか（常にtrue）
return function(args, chat_buffer)
  local mention_picker = require("vibing.application.commands.mention_picker")
  mention_picker.execute()
  return true
end
