---@class Vibing.Application.CompletionNotifier
---A が B にリクエストを送ったという事実そのものを購読の登録として扱い、B が応答を終えたら
---A に「B が止まった、読みに行け」とだけ伝える。
---
---エージェント（CLIプロセス）はターンが終われば死ぬので、待ち受けはできない。受け取り方は
---「A に新しいターンを起こす」しかなく、それがこの設計。B から A への質問も、B が A に
---`nvim_chat_send_message` を呼ぶだけで同じ経路に乗る。
---
---**配達そのものは `message_queue.lua` が持つ。** ここが持つのは購読（`edges`）と暴走抑止
---（`depth`）だけで、どちらもインメモリのみ。Neovim が落ちればワーカーチャットも道連れなので、
---`pending-resume.json` のような永続化に意味がない。
local M = {}

local notify = require("vibing.core.utils.notify")
local MessageQueue = require("vibing.application.chat.message_queue")

local AUGROUP = "VibingCompletionNotifier"
local DEFAULT_MAX_HOPS = 8

---edges[to_bufnr][from_bufnr] = 購読を張った時点の深さ。
---「to_bufnr が終わったら from_bufnr に知らせる」を表す
---@type table<number, table<number, number>>
local edges = {}

---通知チェーンで何回起こされたか。手動送信で 0 に戻る
---@type table<number, number>
local depth = {}

---reported[from_bufnr][to_bufnr] = from が to に自分から送った。
---「次に from が止まったときの watchdog は冗長」を表す、エッジとは別の一時マーク
---@type table<number, table<number, boolean>>
local reported = {}

---@return {enabled: boolean, max_hops: number?}
local function settings()
  local config = require("vibing.config").get()
  return (config.agent and config.agent.chat_notifications) or { enabled = false }
end

---自分宛キューを流し、配達できた通知の深さぶんだけ hop カウンタを上げる
---
---「配達したら上げる」を関数にしてあるのは、`on_response_done` に呼び出し箇所が2つあるため。
---どちらかで書き忘れると `max_hops` が黙って連鎖を止められなくなる
---@param bufnr number
---@return boolean restarted
local function drain(bufnr)
  local restarted, deepest = MessageQueue.flush(bufnr)
  if deepest then
    -- 下げてはいけない。深く連鎖したチャットが、浅い時点で張られたエッジの配達を受けたときに
    -- カウンタが戻ると、max_hops が連鎖を止められなくなる
    depth[bufnr] = math.max(depth[bufnr] or 0, deepest + 1)
  end
  return restarted
end

---A が B に送ったことを購読として記録する
---@param from_bufnr number 送信元（通知を受け取る側）
---@param to_bufnr number 送信先（完了を監視される側）
---@return boolean subscribed 深さ上限などで張らなかった場合 false
function M.subscribe(from_bufnr, to_bufnr)
  local cfg = settings()
  if not cfg.enabled then
    return false
  end

  if type(from_bufnr) ~= "number" or type(to_bufnr) ~= "number" or from_bufnr == to_bufnr then
    return false
  end
  if not (vim.api.nvim_buf_is_valid(from_bufnr) and vim.api.nvim_buf_is_valid(to_bufnr)) then
    return false
  end

  edges[to_bufnr] = edges[to_bufnr] or {}

  -- 同じ (A, B) への複数送信は1本に畳む。A が B に3回送っても通知は1回。
  -- この判定を hop 上限より**前**に置く: 既に張ってあるエッジは生きていて通知も届くのに、
  -- 上限に当たったという理由で「購読しなかった」と警告するのは事実に反する。
  -- 同じワーカーに複数回ブリーフを送るのは `vibing-orchestrate` の通常の手順
  if edges[to_bufnr][from_bufnr] ~= nil then
    return true
  end

  local current = depth[from_bufnr] or 0
  local max_hops = cfg.max_hops or DEFAULT_MAX_HOPS
  if current >= max_hops then
    -- 黙って張らないと、通知が来ない理由がどこにも残らない。A→B→A→B の往復自体は
    -- 正当なユースケース（Bの質問にAが答える）なので、循環検出ではなく深さで止めている
    notify.warn(
      string.format(
        "Chat %d has already been woken %d times without a manual send; not subscribing to chat %d. "
          .. "Send a message in that chat yourself to reset the chain.",
        from_bufnr,
        current,
        to_bufnr
      ),
      "Chat Notifications"
    )
    return false
  end

  edges[to_bufnr][from_bufnr] = current

  return true
end

---`from_bufnr` が `to_bufnr` に送った（即配達でもキュー投入でも）ことを記録する
---
---1つの出来事に対して2つの向きの後始末が要るので、呼び出し元に両方を覚えさせない。
---
---- **購読**: 「to が止まったら from に知らせる」を張る（送ったこと自体が購読の登録）
---- **watchdog の退役**: 「from が止まったら to に知らせる」を落とす。from 自身が口を開いた
---  以上それは同じ用件の二度目で、残すと to は同じことで二度起こされる。`to → from` の送信が
---  あればそこで張り直される
---
---向きが逆なことに注意: 張るのは `edges[to][from]`、抑止するのは `edges[from][to]`
---@param from_bufnr number
---@param to_bufnr number
function M.on_sent(from_bufnr, to_bufnr)
  if type(from_bufnr) ~= "number" or type(to_bufnr) ~= "number" then
    return
  end

  M.subscribe(from_bufnr, to_bufnr)

  -- **エッジそのものは消さない。** 消すと、from が「作業中の途中経過」を送っただけの場合にも
  -- 購読が永久に失われる。ツリー状のチャット網ではそれが常態で、中間ノードは子を待つ間に
  -- 一度停止し、子の報告で再稼働してから本命の報告を書く（#638）。送信の時点では、その
  -- メッセージが最終報告なのか途中経過なのかは機構には分からない。
  -- 代わりに「次の停止1回ぶんだけ黙らせる」印を置き、再稼働したらその印を捨てる
  reported[from_bufnr] = reported[from_bufnr] or {}
  reported[from_bufnr][to_bufnr] = true

  MessageQueue.drop_notification(to_bufnr, from_bufnr)
end

---応答完了。自分宛キューの drain と、購読者への配達を行う
---@param bufnr number
function M.on_response_done(bufnr)
  -- 自分宛キューの drain が先で、しかも設定に関わらず行う。`queue_if_busy` で積まれた本文は
  -- watchdog 通知を切っている環境でも届かなければならない。
  --
  -- 配達できた = bufnr はこのターンでは終わっておらず、続きのターンが控えているということなので、
  -- この完了は購読者に見せない。順序を逆にしても防げない理由と、この規則が拾えない側の順序は
  -- architecture.md → Multi-Agent Orchestration（#638）
  if drain(bufnr) then
    -- edges[bufnr] は消費せずに残す。bufnr が本当に止まったときの完了で配達される。
    -- 再稼働した以上、直前に送ったものは最終報告ではなかったので、抑止の印も捨てる
    reported[bufnr] = nil
    return
  end

  if not settings().enabled then
    return
  end

  local subscribers = edges[bufnr]
  local suppressed = reported[bufnr] or {}
  reported[bufnr] = nil

  if subscribers then
    -- 配達した時点で購読は消える（one-shot）。B が次に完了しても、A が改めて送っていなければ
    -- 通知は飛ばない。自分から報告済みの相手も、購読は同じように使い切る — 用件は届いている
    edges[bufnr] = nil
    for from_bufnr, edge_depth in pairs(subscribers) do
      if not suppressed[from_bufnr] and vim.api.nvim_buf_is_valid(from_bufnr) then
        MessageQueue.enqueue_notification(from_bufnr, bufnr, edge_depth)
      end
    end
    for from_bufnr in pairs(subscribers) do
      drain(from_bufnr)
    end
  end
end

---ユーザーが手動送信したので通知チェーンの深さをリセットする
---@param bufnr number
function M.reset_depth(bufnr)
  depth[bufnr] = nil
end

---バッファが消えたので関連する購読・キューを捨てる
---@param bufnr number
function M.forget(bufnr)
  MessageQueue.forget(bufnr)

  -- autocmdはパターン無しで登録しているので、エディタ内のどのバッファを閉じても走る。
  -- 既定（無効）では状態が空のまま、全テーブルの走査だけが通常の編集操作ごとに起きる。
  -- キューは自分の空振りを自分で弾くので、ここで見るのは自分の状態だけ
  if not (next(edges) or next(depth) or next(reported)) then
    return
  end

  edges[bufnr] = nil
  depth[bufnr] = nil
  reported[bufnr] = nil

  for _, subscribers in pairs(edges) do
    subscribers[bufnr] = nil
  end
  for _, targets in pairs(reported) do
    targets[bufnr] = nil
  end
end

---autocmdを登録する
---
---`enabled` はここでは見ない。イベント自体は設定に関わらず発火するので、購読側でだけ判定して
---おけば、実行中に設定を変えた場合も追従する。無効時のコストは1ターンにつき空振り1回
function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VibingResponseDone",
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if type(bufnr) == "number" then
        M.on_response_done(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      M.forget(event.buf)
    end,
  })
end

return M
