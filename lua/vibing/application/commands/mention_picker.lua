local notify = require("vibing.core.utils.notify")

local M = {}

---セッションピッカーを表示してメンションを送る
function M.execute()
  local chat_controller = require("vibing.presentation.chat.controller")
  local chat_buffer = chat_controller.get_active_chat_buffer()

  if not chat_buffer then
    notify.warn("No active chat buffer. Open a chat first with :VibingChat")
    return
  end

  if not chat_buffer._shared_buffer_enabled then
    notify.warn("Shared buffer integration is not enabled. Enable it with /enable-shared")
    return
  end

  local dispatcher = require("vibing.application.shared_buffer.notification_dispatcher")
  local sessions = dispatcher.get_registered_sessions()
  local count = dispatcher.get_session_count()

  if count == 0 then
    notify.warn("No Claude sessions registered. Enable shared buffer in other chats first.")
    return
  end

  -- セッション一覧を作成
  local session_list = {}
  for claude_id, session in pairs(sessions) do
    table.insert(session_list, {
      id = claude_id,
      session_id = session.session_id,
      bufnr = session.bufnr,
    })
  end

  -- アルファベット順にソート
  table.sort(session_list, function(a, b)
    return a.id < b.id
  end)

  -- @All オプションを追加
  table.insert(session_list, 1, {
    id = "All",
    session_id = "broadcast",
    bufnr = -1,
  })

  -- ピッカーを表示
  vim.ui.select(session_list, {
    prompt = "Select Claude session to mention:",
    format_item = function(item)
      if item.id == "All" then
        return "📢 @All (Broadcast to all sessions)"
      else
        return string.format("💬 @%s (session: %s)", item.id, item.session_id:sub(1, 8))
      end
    end,
  }, function(choice)
    if not choice then
      return
    end

    -- メッセージ入力を促す
    vim.ui.input({
      prompt = string.format("Message to @%s: ", choice.id),
    }, function(message)
      if not message or message == "" then
        notify.warn("Message cannot be empty")
        return
      end

      -- メンションを送信
      local mentions = choice.id == "All" and { "All" } or { choice.id }
      chat_buffer:post_to_shared_buffer(message, mentions)

      notify.info(string.format("Mentioned @%s in shared buffer", choice.id))
    end)
  end)
end

return M
