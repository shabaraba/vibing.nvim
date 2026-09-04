---@class Vibing.Presentation.Chat.CacheExpiryPrompt
---期限切れのプロンプトキャッシュを書き直す送信の手前に、1回だけ確認を出す。
---判定そのものは `application/chat/cache_expiry`。
---
---**確認を出せるのは人間の `<CR>` だけで、それは置き場所で担保している。**
---`ChatBuffer:send_message()` は予約の発火・auto_resume・チャット間の配達・承認の代理応答も
---通る合流点なので、そこに置くと無人送信が `vim.ui.select` の前で止まって二度と進まない。
---呼び出し元は `buffer.lua` のキーマップ closure ひとつだけで、同じ理由で
---`send_message()` の戻り値契約（`ProgrammaticSender` / `message_queue` / `fire_scheduled` が
---読む boolean）にも触らずに済む。
---
---どの経路も失敗したら送信に倒す（fail open）。判定はコストの助言であって、送信を止める
---権限は持たない。
local M = {}

local CacheExpiry = require("vibing.application.chat.cache_expiry")
local TokenUsage = require("vibing.core.utils.token_usage")

---@param decision Vibing.CacheExpiry.Decision
---@return string
local function format_prompt(decision)
  local AutoResume = require("vibing.application.chat.auto_resume")
  return string.format(
    "This chat's prompt cache has likely expired: the last turn ended %s ago, so sending now "
      .. "rewrites ~%s tokens.",
    AutoResume.format_duration(decision.elapsed_sec),
    TokenUsage.humanize(decision.context)
  )
end

---未送信本文を新しいチャットに移して開く
---@param chat_buffer Vibing.ChatBuffer
local function continue_in_new_chat(chat_buffer)
  local notify = require("vibing.core.utils.notify")
  local CarryOver = require("vibing.application.chat.use_cases.carry_over")

  local session, err = CarryOver.execute(chat_buffer, chat_buffer:extract_user_message())
  if not session then
    return notify.error(err or "Failed to start a new chat")
  end

  require("vibing.presentation.chat.controller").open_continuation(session, nil, "Continuing in")
end

---手動送信の直前に呼ぶゲート。確認が要らなければ `proceed` を同期で呼ぶ
---@param chat_buffer Vibing.ChatBuffer
---@param proceed fun() そのまま送信する処理
function M.guard(chat_buffer, proceed)
  local ok, decision = pcall(CacheExpiry.evaluate, chat_buffer)
  if not ok or not decision then
    return proceed()
  end

  local choices = {
    { label = "Send anyway", action = "send" },
    { label = "Continue in a new chat (moves this message there)", action = "new" },
    { label = "Cancel", action = "cancel" },
  }

  vim.ui.select(choices, {
    prompt = format_prompt(decision),
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    -- 選ばずに閉じた場合は Cancel と同じ。未送信本文はバッファに残るので、何もしないのが
    -- 「やめた」の正しい姿になる
    if not choice or choice.action == "cancel" then
      return
    end
    if choice.action == "send" then
      return proceed()
    end
    continue_in_new_chat(chat_buffer)
  end)
end

return M
