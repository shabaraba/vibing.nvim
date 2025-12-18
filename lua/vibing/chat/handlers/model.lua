local notify = require("vibing.utils.notify")

---/modelコマンドハンドラー
---チャット内で/model <model>を実行した際に呼び出される
---使用するClaudeモデルを設定（opus, sonnet, haiku）
---設定値はチャットファイルのYAMLフロントマターに保存され、次回以降のメッセージ送信時に使用
---有効なモデルの検証と通知を実施
---@param args string[] コマンド引数（args[1]がモデル: opus/sonnet/haiku）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean モデル設定に成功した場合true、引数不足や無効なモデルの場合false
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local model = args[1]
  local valid_models = { "opus", "sonnet", "haiku" }
  local is_valid = false

  for _, valid_model in ipairs(valid_models) do
    if model == valid_model then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid model: %s (valid: opus, sonnet, haiku)", model))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("model", model)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Model set to: %s", model))
  return true
end
