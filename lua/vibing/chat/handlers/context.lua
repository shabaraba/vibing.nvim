local notify = require("vibing.utils.notify")

---/contextコマンドハンドラー
---チャット内で/context <file_path>を実行した際に呼び出される
---指定されたファイルパスを次回以降のプロンプトに含めるコンテキストとして追加
---ファイルパス展開（~やシンボリックリンク解決）と存在チェックを実施
---追加成功後、チャットバッファのコンテキスト表示行を更新
---@param args string[] コマンド引数（args[1]がファイルパス）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean ファイル追加に成功した場合true、引数不足や読み込み不可の場合false
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/context <file_path>", "Usage")
    return false
  end

  local file_path = args[1]

  -- ファイルパスを展開
  local expanded_path = vim.fn.expand(file_path)

  -- ファイルが存在するかチェック
  if vim.fn.filereadable(expanded_path) ~= 1 then
    notify.error(string.format("File not readable: %s", expanded_path))
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
