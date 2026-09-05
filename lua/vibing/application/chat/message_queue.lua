---@class Vibing.Application.MessageQueue
---チャットバッファ宛の「いま配達できないもの」を溜めて、そのバッファが止まった瞬間に
---1ターンにまとめて届ける。
---
---エージェント（CLIプロセス）はターンが終われば死ぬので、待ち受けはできない。何かを届ける
---唯一の方法は**新しいターンを起こすこと**で、それは相手が応答中でない瞬間にしか行えない
---（応答中に送ると `ChatBuffer:send_message()` が進行中のターンを kill する）。この待ち合わせが
---このモジュールの全部。
---
---積まれるものは2種類あり、どちらも同じ待ち合わせを必要とする:
---
---- 通知 — 「あのチャットが止まった、読みに行け」（`completion_notifier` の watchdog）
---- 本文 — 送信元のテキストそのもの（`nvim_chat_send_message` の `queue_if_busy`）
---
---キューは**インメモリのみ**。Neovim が落ちればワーカーチャットも道連れなので、永続化に意味がない。
local M = {}

local notify = require("vibing.core.utils.notify")

---1バッファに溜められる上限。超えたら**捨てずに拒否する**: 捨てると報告が黙って消え、
---それはこのモジュールが防ぐために存在しているものそのものになる
local MAX_QUEUED = 20

local WARN_TITLE = "Chat Delivery"

---@class Vibing.Application.MessageQueue.Item
---@field bufnr number? 相手のチャット。通知なら応答を終えた側、本文なら送信元（本文では任意）
---@field body string? 配達する本文。**これがあるかどうかが種別**で、別途フラグは持たない
---@field reason string? 通知のみ。自力では抜けられない止まり方をしたならその理由
---  （`ChatBuffer:get_stop_reason()`）。読み手が `nvim_get_buffer` を1往復せずに
---  「答えれば動く」のか「ユーザーにしか外せない」のかを判断できるようにするためで、
---  普通に止まっただけの watchdog 通知では nil

---@type table<number, Vibing.Application.MessageQueue.Item[]>
local pending = {}

---@param to_bufnr number
---@param predicate fun(item: Vibing.Application.MessageQueue.Item): boolean
local function remove_where(to_bufnr, predicate)
  local queue = pending[to_bufnr]
  if not queue then
    return
  end

  for i = #queue, 1, -1 do
    if predicate(queue[i]) then
      table.remove(queue, i)
    end
  end

  if #queue == 0 then
    pending[to_bufnr] = nil
  end
end

---配達される本文について、オーケストレーション関係を frontmatter に書く
---
---即配達経路（`rpc/handlers/message.lua`）は送信の**前**に書くが、こちらはそれができない。
---キューに積まれる条件が「宛先が応答中」で、`update_frontmatter_list` はその宛先バッファを
---直接編集するため、積んだ時点で書くとストリーミングと競合する。`flush` が配達するのは宛先が
---idle のときだけなので、ここが唯一安全な瞬間になる
---@param queue Vibing.Application.MessageQueue.Item[]
---@param to_bufnr number
local function write_links(queue, to_bufnr)
  local OrchestrationLink = require("vibing.application.chat.orchestration_link")
  local seen = {}
  for _, item in ipairs(queue) do
    -- 同じ送信元からの複数の本文はリンク1本。`link` 自身も重複を弾くが、そこに至るまでに
    -- frontmatter を2回パースするので手前で止める（orchestration_link.lua の早期returnを参照）
    if item.body and item.bufnr and not seen[item.bufnr] then
      seen[item.bufnr] = true
      OrchestrationLink.link_or_warn(item.bufnr, to_bufnr)
    end
  end
end

---「done_bufnr が止まった」という通知を積む
---
---同じチャットについて二重には積まない。宛先が忙しい間に同じワーカーが2度止まっても、
---伝えるべきことは「止まった、読みに行け」の1回きり。ただし**理由は後勝ちで上書きする**:
---2度目が承認待ちなら、そちらが宛先の見るべき現在の状態で、1度目の（理由なしの）通知に
---合流させると「読みに行け」だけが残って何で詰まっているかが落ちる
---@param to_bufnr number
---@param done_bufnr number
---@param reason string? 自力では抜けられない止まり方をしたならその理由
function M.enqueue_notification(to_bufnr, done_bufnr, reason)
  local queue = pending[to_bufnr] or {}
  for _, item in ipairs(queue) do
    if not item.body and item.bufnr == done_bufnr then
      item.reason = reason or item.reason
      return
    end
  end

  if #queue >= MAX_QUEUED then
    -- 呼び出し元は既にエッジを消費しているので、黙って捨てると通知は二度と再現しない
    notify.warn(
      string.format(
        "Chat %d already has %d items queued; dropping the completion notice for chat %d",
        to_bufnr,
        #queue,
        done_bufnr
      ),
      WARN_TITLE
    )
    return
  end

  table.insert(queue, { bufnr = done_bufnr, reason = reason })
  pending[to_bufnr] = queue
end

---本文を積む
---@param to_bufnr number
---@param from_bufnr number?
---@param body string
---@return boolean ok
---@return string? err 積まなかった理由。送信元に返して伝える
function M.enqueue_message(to_bufnr, from_bufnr, body)
  -- 空の本文は待っても送れるようにならない。積めば `ProgrammaticSender` が配達時に弾き、
  -- そのときにはもう送信元に伝える先がない
  if type(body) ~= "string" or vim.trim(body) == "" then
    return false, "Empty message"
  end

  local queue = pending[to_bufnr] or {}
  if #queue >= MAX_QUEUED then
    return false,
      string.format(
        "Chat buffer %d already has %d messages waiting for it; not queueing another. "
          .. "Wait for it to catch up before sending again.",
        to_bufnr,
        #queue
      )
  end

  table.insert(queue, { bufnr = from_bufnr, body = body })
  pending[to_bufnr] = queue
  return true
end

---`about_bufnr` についての滞留通知を落とす
---
---その相手から本文が直接届くなら、「止まった、読みに行け」は冗長になる
---@param to_bufnr number
---@param about_bufnr number
function M.drop_notification(to_bufnr, about_bufnr)
  remove_where(to_bufnr, function(item)
    return not item.body and item.bufnr == about_bufnr
  end)
end

---配達待ちを抱えているか
---
---並列度上限の判定を配達より**前**に置くために要る。上限に当たっているかを先に見て、
---キューが空なら見送りとして数えない — 空のキューは「上限で待たされている」ではないので、
---枠が空くたびに配り直す対象に入ってしまう
---@param to_bufnr number
---@return boolean
function M.has_pending(to_bufnr)
  local queue = pending[to_bufnr]
  return queue ~= nil and #queue > 0
end

---溜まったものを1ターンにまとめて配達する
---
---相手が応答中なら**何もしない**。応答中のバッファに送ると `ChatBuffer:send_message()` が
---進行中のターンを kill する（buffer.lua の「前のリクエストが実行中ならキャンセル」）。
---積んだままにしておけば、相手自身の `VibingResponseDone` でここが呼び直される。
---@param to_bufnr number
---@return boolean restarted 配達の結果 to_bufnr が新しいターンを走らせた
---@return number[]? delivered 配達できたとき、その中の通知が指していたチャットの一覧。
---  **配達したかどうかの signal も兼ねる**ので、本文だけを配ったときも空tableで返る（nilは
---  「配達しなかった」）。呼び出し元はこれで暴走抑止のカウンタを進める
function M.flush(to_bufnr)
  local queue = pending[to_bufnr]
  if not queue or #queue == 0 then
    return false
  end

  if not vim.api.nvim_buf_is_valid(to_bufnr) then
    pending[to_bufnr] = nil
    return false
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(to_bufnr)
  if not chat_buf then
    pending[to_bufnr] = nil
    return false
  end

  if chat_buf:is_responding() then
    return false
  end

  -- ユーザーが書きかけの `## User` を残しているなら触らない。配達は新しいセクションを足すので、
  -- 下書きは送られないまま宙に浮き、次の<CR>は空のヘッダを読んで「No message to send」になる。
  -- auto_resume が未送信セクションを上書きしないのと同じ扱い。
  -- ユーザーがその下書きを送れば、そのターンの完了でここが呼び直されるので取りこぼさない
  if chat_buf.extract_user_message then
    local draft = chat_buf:extract_user_message()
    if draft and vim.trim(draft) ~= "" then
      return false
    end
  end

  local delivered = {}
  for _, item in ipairs(queue) do
    if not item.body and item.bufnr then
      table.insert(delivered, item.bufnr)
    end
  end

  -- 送信の成否を待たずに書く。順序は即配達経路と同じ（リンクが先、送信が後）で、理由も同じ:
  -- `addUserSection` が走ったあとに frontmatter を触ると、始まったストリーミングと競合する。
  -- 送信が失敗したときはキューが残って再試行されるので、いずれ辻褄は合う。恒久的に失敗し続ける
  -- 相手についてだけは「一度も届いていない関係」が記録に残るが、`link` は重複を弾くので
  -- 増えはしないし、リンクは記録であって配達の証明ではない
  write_links(queue, to_bufnr)

  local DeliveryMessage = require("vibing.application.chat.delivery_message")
  local ok, result = pcall(DeliveryMessage.deliver, queue, to_bufnr)

  -- 配達できて初めてキューを空ける。通知側はエッジを既に消費しているので、先に捨てると
  -- 失敗した配達は二度と再現しない。残しておけば次の完了イベントで作り直しなしに再試行できる
  if ok and result and result.success then
    pending[to_bufnr] = nil

    -- 送信が受理されたことと、ターンが始まったことは別。`ChatBuffer:send_message()` が返すのは
    -- 「リクエストとして扱ったか」で、リミット中の予約（`_try_schedule_instead_of_send`）でも、
    -- `SendMessage.execute` がアダプタ未設定・セッション競合で降りた場合でも true になる。
    -- 後者はストリームを張らないので `VibingResponseDone` が来ず、呼び出し元がこれを再稼働と
    -- 読むとエッジが宙に浮く。始まっていないターンを購読者の待ち先にはできないので、
    -- 送信結果ではなく相手の状態を返す
    return chat_buf:is_responding(), delivered
  end

  notify.warn(
    string.format("Could not deliver to chat %d: %s", to_bufnr, ok and "the chat refused the message" or tostring(result)),
    WARN_TITLE
  )
  return false
end

---バッファが消えたので、その宛先のキューと、他のキューに残る言及を始末する
---
---`item.bufnr` は2つの意味を持つので、扱いも2つに分かれる。
---
---- **通知**では「止まったチャット」。それが消えた以上「読みに行け」は宛先を失うので捨てる
---- **本文**では送信元の記録にすぎない。表示とリンクのためのメタデータで、本文そのものの
---  届け先とは無関係なので、送信元が消えても配達はできる。ここで捨てると「報告が黙って
---  消える」— このモジュールが防ぐために存在しているものそのものになる。名前だけ落として
---  匿名の本文として残す（`delivery_message` は送信元なしの形を元から扱える）。
---  同時に、消えたバッファへの `link_or_warn` が配達のたびに警告するのも防げる
---
---`BufDelete` はパターン無しで張られていて、エディタ内のどのバッファを閉じても走る。
---既定（この機能は未使用）では空振りなので、自分の状態が空なら何もしない
---@param bufnr number
function M.forget(bufnr)
  if next(pending) == nil then
    return
  end

  pending[bufnr] = nil

  for to_bufnr, queue in pairs(pending) do
    for _, item in ipairs(queue) do
      if item.body and item.bufnr == bufnr then
        item.bufnr = nil
      end
    end

    remove_where(to_bufnr, function(item)
      return not item.body and item.bufnr == bufnr
    end)
  end
end

return M
