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
---3. 打ち切り、または何らかの停止理由つきで終わった → 送らずに未送信セクションへ戻す
---   （`park_in_unsent_section`）
---4. それ以外 → 未送信セクションに書いて、`<CR>` と同じ `send_message` で送る
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

  -- `auto_compact` が `/compact` の後に送り直す本文を抱えているあいだは譲る。あちらの再送は
  -- 「送る瞬間に応答中なら黙って諦める」ので、こちらが先に送るとその本文が消える。
  -- ターン終了時の順序の問題は `on_response_done` 側で扱う（あちらは `pending` を同期で
  -- 消すので、ここに来た時点ではもう見えない）。ここで効くのは `add` から直接来た経路
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

  -- 停止理由は**許可リストで**見る: 理由が無い＝普通に終わった、のときだけ送る。`"error"` を
  -- 名指しする形にすると、将来増えた停止理由が黙って「送る」側に倒れる
  if chat_buf:was_cancelled() or chat_buf:get_stop_reason() ~= nil then
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

  -- `<CR>` と同じ形で送る: 未送信セクションに書き、自動 `/compact` の判定を通してから
  -- `send_message`。`ProgrammaticSender.send` はチャット間配達の入口で `before_manual_send` を
  -- 通らないので、それを使うと予約だけが閾値を越えた会話に `/compact` 無しで積まれる。
  -- キャッシュ期限切れの確認（`cache_expiry_prompt.guard`）は通さない: 直前のターンがいま
  -- 終わったところなので期限は切れておらず、通すと無人の送信が `vim.ui.select` で止まりうる
  --
  -- 書いてから送るので、送れなかったときも本文は未送信セクションに残る。消えない
  park_in_unsent_section(bufnr, message)
  pcall(function()
    require("vibing.application.chat.auto_compact").before_manual_send(chat_buf)
  end)
  local ok, sent = pcall(function()
    return chat_buf:send_message()
  end)
  if ok and sent then
    return "sent"
  end

  notify.warn(
    string.format(
      "Could not send the reserved message(s)%s. They are in the unsent section.",
      ok and "" or (": " .. tostring(sent))
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
  -- **同期で見る。** `auto_compact.on_response_done` は `pending` を同期で消してから再送を
  -- schedule するので、下の schedule の中で `has_pending` を訊いても、購読順によっては既に
  -- false になっている — 先に走ったこちらの送信があちらの再送を「応答中」で黙って潰す。
  -- 購読順に依らないよう、この時点で抱えているなら今回は見送る。再送したターンが終われば
  -- もう一度ここに来る
  if require("vibing.application.chat.auto_compact").has_pending(bufnr) then
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
