---@class Vibing.Application.Reservations
---応答中のチャットに対する「予約送信」。人間が応答の終わりを待たずに次の指示を書いておき、
---そのターンが終わった瞬間に、予約した順に改行で join した**1つの**リクエストとして送る。
---
---`message_queue` とは別物にしてある。あちらはチャット間の配達で、見出しは `## Request` /
---`## Report` / `## Notice`、上限もリンク書き込みも永続化もそのためにある。予約は人間自身の
---次の発言なので `## User` で送られ、どれも要らない。1つのキューに混ぜると、どちらの規約で
---扱うかの分岐が配達のたびに要る。
---
---**インメモリだけ。** Neovim を閉じれば予約は消える。応答中のターンそのものも Neovim と一緒に
---止まるので、「終わったら送る」の前提が残らない。
---
---状態はチャットバッファごとで、`[bufnr] = { "本文", ... }` の1本だけ。
local M = {}

local notify = require("vibing.core.utils.notify")

local AUGROUP = "VibingReservations"
local TITLE = "Reserved Message"

---@type table<number, string[]>
local pending = {}

---@param bufnr number
---@return table? chat_buf
local function chat_buffer_of(bufnr)
  if not (type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  return require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
end

---@param bufnr number
---@return string[]
function M.list(bufnr)
  return vim.deepcopy(pending[bufnr] or {})
end

---@param bufnr number
---@return number
function M.count(bufnr)
  local items = pending[bufnr]
  return items and #items or 0
end

---予約を全部取り消す
---@param bufnr number
---@return number cleared 取り消した件数
function M.clear(bufnr)
  local count = M.count(bufnr)
  pending[bufnr] = nil
  return count
end

---バッファが消えた。送り先の無い予約は捨てる
---@param bufnr number
function M.forget(bufnr)
  pending[bufnr] = nil
end

---予約本文を末尾の未送信 `## User` セクションに書き、送らずに置く
---
---打ち切り・エラーで終わったターンのあとに黙って送ると、止めた直後に新しいターンが勝手に
---始まる — `:VibingCancelTree` が配達待ちを先に捨てているのと同じ理由でそれはしない。
---かといって捨てると人間が書いたものが消えるので、編集できる形で入力欄に戻す。
---送るかどうかは人間が `<CR>` で決める
---@param bufnr number
---@param message string
local function park_in_unsent_section(bufnr, message)
  local ConversationExtractor = require("vibing.presentation.chat.modules.conversation_extractor")
  local Renderer = require("vibing.presentation.chat.modules.renderer")
  ConversationExtractor.drop_trailing_unsent_section(bufnr)
  Renderer.addUserSection(bufnr, nil, nil, nil, message)
end

---予約を送る。応答中なら何もしない（次の `VibingResponseDone` で呼び直される）
---
---**送るのは「普通に終わったターン」のあとだけ。** 分岐は4つ:
---
---1. まだ応答中 → 待つ
---2. 未送信セクションに既に何かある（プロンプトが描いてある・人間の下書きがある）→ 待つ。
---   そこに足すと承認の選択肢行や質問への答えと混ざり、送るとそれらが本文として届く。
---   その下書きが送られれば、そのターンの終わりでここがもう一度呼ばれる
---3. 打ち切り・エラーで終わった → 送らずに未送信セクションへ戻す（`park_in_unsent_section`）
---4. それ以外 → `ProgrammaticSender.send` で `## User` として送る
---@param bufnr number
---@return "sent"|"parked"|"waiting"|"none" outcome
function M.flush(bufnr)
  local items = pending[bufnr]
  if not items or #items == 0 then
    return "none"
  end

  local chat_buf = chat_buffer_of(bufnr)
  if not chat_buf then
    pending[bufnr] = nil
    return "none"
  end

  if chat_buf:is_responding() then
    return "waiting"
  end

  -- `auto_compact` is registered after us (`init.lua`), so on the tick a compaction turn finishes,
  -- its own `on_response_done` runs after ours and still has to write its parked message back and
  -- send it. Flushing here first would find the chat briefly idle, start sending, and auto_compact's
  -- own scheduled send would then find `is_responding()` true and silently drop the message it was
  -- holding — the exact "whichever ran second found the chat responding" loss its module comment
  -- describes. Waiting for the next `VibingResponseDone` (fired when that send itself finishes)
  -- avoids the race instead of depending on subscriber order.
  if require("vibing.application.chat.auto_compact").has_pending(bufnr) then
    return "waiting"
  end

  if chat_buf:has_unanswered_prompts() then
    notify.info(
      string.format("%d reserved message(s) will be sent after the prompt above is answered", #items),
      TITLE
    )
    return "waiting"
  end

  local draft = chat_buf:extract_user_message()
  if draft and vim.trim(draft) ~= "" then
    notify.info(
      string.format("%d reserved message(s) will be sent after your unsent message", #items),
      TITLE
    )
    return "waiting"
  end

  local message = table.concat(items, "\n")
  pending[bufnr] = nil

  if chat_buf:was_cancelled() or chat_buf:get_stop_reason() == "error" then
    park_in_unsent_section(bufnr, message)
    notify.warn(
      string.format(
        "The turn did not finish normally, so %d reserved message(s) were not sent. "
          .. "They are in the unsent section; press <CR> to send them.",
        #items
      ),
      TITLE
    )
    return "parked"
  end

  -- 人間が書いた発言なので、手動送信と同じく往復カウンタを戻す（`_setup_keymaps` の
  -- `send_message` と同じ扱い）。無人の配達ではない
  pcall(function()
    require("vibing.application.chat.completion_notifier").on_manual_send(bufnr)
  end)

  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
  local ok, result = pcall(ProgrammaticSender.send, bufnr, message)
  if ok and result and result.success then
    return "sent"
  end

  -- 送れなかった本文を消さない。`send` が未送信セクションを書いたあとで弾かれたなら、本文は
  -- もうそこにある。書く前に弾かれたなら、ここで書く
  local after = chat_buf:extract_user_message()
  local has_draft = after and vim.trim(after) ~= ""
  if not has_draft then
    park_in_unsent_section(bufnr, message)
  end
  notify.warn(
    string.format(
      "Could not send the reserved message(s)%s. They are in the unsent section.",
      ok and "" or (": " .. tostring(result))
    ),
    TITLE
  )
  return "parked"
end

---予約を1件足す
---
---応答中でなければその場で `flush` する。入力欄を開いてから確定するまでのあいだにターンが
---終わることがあり、そこで断ると人間が書いたものが行き場を失う — 「終わったら送る」の
---「終わった」が少し早く来ただけなので、そのまま送ればよい
---@param bufnr number
---@param text string
---@return boolean ok
---@return string? err
function M.add(bufnr, text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return false, "Empty message"
  end
  local chat_buf = chat_buffer_of(bufnr)
  if not chat_buf then
    return false, "Not a vibing chat buffer"
  end

  pending[bufnr] = pending[bufnr] or {}
  table.insert(pending[bufnr], text)

  if chat_buf:is_responding() then
    notify.info(
      string.format("Reserved (%d queued). Sent when the current response finishes.", #pending[bufnr]),
      TITLE
    )
    return true
  end

  M.flush(bufnr)
  return true
end

---ターン終了時の購読
---@param bufnr number
function M.on_response_done(bufnr)
  if not pending[bufnr] then
    return
  end
  -- `_finish_turn` の中から同期で呼ばれる。そこから新しいターンを始めると、まだ戻っていない
  -- `_handle_response` の後始末と新しいターンの立ち上げが入れ子になるので、1ティック置く
  vim.schedule(function()
    M.flush(bufnr)
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  require("vibing.core.events").on_response_done(group, "reservations", M.on_response_done)

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      M.forget(event.buf)
    end,
  })
end

---@private テスト用
function M._reset()
  pending = {}
end

return M
