local notify = require("vibing.utils.notify")

local VALID_MODES = { "default", "acceptEdits", "bypassPermissions" }

---/permissionコマンドハンドラー
---チャット内で/permission <mode>を実行した際に呼び出される
---Agent SDKの権限モードを設定（default, acceptEdits, bypassPermissions）
---設定値はチャットファイルのYAMLフロントマターに保存され、次回以降のメッセージ送信時に使用
---引数なしで現在の権限モードを表示
---@param args string[] コマンド引数（args[1]がモード）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 成功した場合true
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  -- 引数なしの場合は現在のモードを表示
  if #args == 0 then
    local frontmatter = chat_buffer:parse_frontmatter()
    local current = frontmatter.permission_mode or "(using config default)"
    notify.info("Permission mode: " .. current)
    notify.info("Valid modes: " .. table.concat(VALID_MODES, ", "))
    return true
  end

  local mode = args[1]
  local is_valid = false

  for _, valid_mode in ipairs(VALID_MODES) do
    if mode == valid_mode then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid permission mode: %s", mode))
    notify.info("Valid modes: " .. table.concat(VALID_MODES, ", "))
    return false
  end

  local success = chat_buffer:update_frontmatter("permission_mode", mode)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Permission mode set to: %s", mode))
  return true
end
