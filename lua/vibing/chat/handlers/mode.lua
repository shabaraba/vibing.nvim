local notify = require("vibing.utils.notify")

---/modeコマンドハンドラー
---チャット内で/mode <mode>を実行した際に呼び出される
---Agent SDKの実行モードを設定（auto, plan, code）
---設定値はチャットファイルのYAMLフロントマターに保存され、次回以降のメッセージ送信時に使用
---有効なモードの検証と通知を実施
---@param args string[] コマンド引数（args[1]がモード: auto/plan/code）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean モード設定に成功した場合true、引数不足や無効なモードの場合false
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/mode <mode>", "Usage")
    return false
  end

  local mode = args[1]
  local valid_modes = { "auto", "plan", "code" }
  local is_valid = false

  for _, valid_mode in ipairs(valid_modes) do
    if mode == valid_mode then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid mode: %s (valid: auto, plan, code)", mode))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("mode", mode)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Mode set to: %s", mode))
  return true
end
