---@class Vibing.Application.DraftHold
---ユーザーの書きかけの `## User` に塞がれた配達を覚えておいて、その下書きが空いた瞬間に
---配り直す。
---
---`message_queue.flush` が配達を見送る理由は2つあり、性質がまったく違う。
---
---- **宛先が応答中** — 一時的で、自分で解ける。宛先自身のターン終了（`VibingResponseDone`）が
---  `completion_notifier` 経由で `flush` を呼び直すので、覚えておく必要は無い
---- **未送信の下書きがある** — **いつ解けるかは人間次第で、解けたことを告げるイベントが無い**。
---  誰も配り直さないので、配達は次にそのチャットのターンが終わるまで宙に浮く。そのターンを
---  起こすのは普通ユーザーの送信なので、「配達のために配達されるべき起床を待つ」循環になる
---  （#831）。下書きを書きかけて離席すれば、待つ相手は永久に来ない
---
---後者だけをここが引き受ける。下書きが消えた合図はバッファの変更そのものなので、見送った宛先に
---`TextChanged` / `InsertLeave` を張って待つ。ポーリングは張らない。
local M = {}

local notify = require("vibing.core.utils.notify")

local TITLE = "Chat Delivery"

---監視中の宛先。`[to_bufnr] = autocmd id[]`
---@type table<number, number[]>
local watching = {}

---`vim.schedule` 済みの配り直し。`[to_bufnr] = true`
---
---`TextChanged` は1回の編集操作でも複数回発火しうるので、予約が積み上がるのを防ぐ。配達は
---重複しても `flush` がキューを空にした時点で空振りになるが、そのたびに `drain` が
---並列度を数え直すのは無駄
---@type table<number, boolean>
local scheduled = {}

---@param bufnr number
---@return string
local function label_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return string.format("chat buffer %d", bufnr)
  end
  return vim.fn.fnamemodify(name, ":t")
end

---いま配達を試してよいか
---
---**判定の順序が要点。** ストリーミング中はレンダラがバッファを書き換えるので `TextChanged` が
---連続して発火する。`extract_user_message` はバッファ全行を読んで最後のユーザーセクションまで
---遡るので、応答中の判定をその手前に置かないと、長いチャットでは変更1回ごとに全行走査が走る
---@param to_bufnr number
---@return boolean
local function can_deliver_now(to_bufnr)
  if not vim.api.nvim_buf_is_valid(to_bufnr) then
    return false
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(to_bufnr)
  if not chat_buf then
    return false
  end

  if chat_buf:is_responding() then
    return false
  end

  if not chat_buf.extract_user_message then
    return true
  end
  local draft = chat_buf:extract_user_message()
  return not (draft and vim.trim(draft) ~= "")
end

---@param to_bufnr number
local function on_buffer_changed(to_bufnr)
  local MessageQueue = require("vibing.application.chat.message_queue")

  if not MessageQueue.has_pending(to_bufnr) then
    -- 別の経路（宛先自身のターン終了）が先に配り終えていた。監視の役目は済んでいる
    M.forget(to_bufnr)
    return
  end

  if scheduled[to_bufnr] or not can_deliver_now(to_bufnr) then
    return
  end

  -- 配達はセクションの追記・チャットファイルの保存・CLIの起動まで行う。テキスト変更イベントの
  -- 中で走らせるものではないので、1tick 遅らせてから同じ判定をやり直す
  scheduled[to_bufnr] = true
  vim.schedule(function()
    scheduled[to_bufnr] = nil
    if not MessageQueue.has_pending(to_bufnr) or not can_deliver_now(to_bufnr) then
      return
    end
    require("vibing.application.chat.completion_notifier").retry_delivery(to_bufnr)
  end)
end

---`to_bufnr` の下書きが空くのを待つ
---
---既に待っているなら何もしない — 通知も再送しない。同じ下書きについて見送るたびに声を出せば、
---意味のある通知まで一緒に訓練で消される
---@param to_bufnr number
---@param pending_count number 見送った配達の件数。通知の本文に出す
function M.watch(to_bufnr, pending_count)
  if watching[to_bufnr] or not vim.api.nvim_buf_is_valid(to_bufnr) then
    return
  end

  local ids = {}
  for _, event in ipairs({ "TextChanged", "InsertLeave" }) do
    table.insert(
      ids,
      vim.api.nvim_create_autocmd(event, {
        buffer = to_bufnr,
        desc = "vibing: retry a delivery held behind an unsent message",
        callback = function()
          on_buffer_changed(to_bufnr)
        end,
      })
    )
  end
  watching[to_bufnr] = ids

  -- `auto_resume` が同じ状況で出すものと同じ作法。配達自体は失われていないので WARN ではない。
  --
  -- **どうすれば流れるかは断定しない。** 塞いでいるのは「空でない未送信セクション」であって、
  -- ユーザーの書きかけとは限らない: 承認・質問のプロンプトを描いたまま kill されたターンの
  -- 残りもここに入る（`completion_notifier` の分岐2の例外が同じ状態を指している）。そちらは
  -- 消すのではなく答えるべきもので、「clear してください」は間違った指示になる
  notify.info(
    string.format(
      "%s has %d message(s) waiting for delivery, held behind an unsent section in that chat. "
        .. "They arrive once that section is sent, answered or emptied.",
      label_of(to_bufnr),
      pending_count
    ),
    TITLE
  )
end

---監視をやめる
---@param to_bufnr number
function M.forget(to_bufnr)
  local ids = watching[to_bufnr]
  if not ids then
    return
  end

  watching[to_bufnr] = nil
  scheduled[to_bufnr] = nil
  for _, id in ipairs(ids) do
    -- バッファが wipeout まで進んでいれば Neovim が既にバッファローカルの autocmd を
    -- 落としている。消えた id を消そうとすると例外になる
    pcall(vim.api.nvim_del_autocmd, id)
  end
end

---@param to_bufnr number
---@return boolean
function M.is_watching(to_bufnr)
  return watching[to_bufnr] ~= nil
end

return M
