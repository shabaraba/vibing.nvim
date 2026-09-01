---@class Vibing.Application.CompletionNotifier
---A が B にリクエストを送ったという事実そのものを購読の登録として扱い、B が応答を終えたら
---A に「B が止まった、読みに行け」とだけ伝える。
---
---エージェント（CLIプロセス）はターンが終われば死ぬので、待ち受けはできない。受け取り方は
---「A に新しいターンを起こす」しかなく、それがこの設計。B から A への質問も、B が A に
---`nvim_chat_send_message` を呼ぶだけで同じ経路に乗る。
---
---**配達そのものは `message_queue.lua` が持つ。** ここが持つのは購読（`edges`）と暴走抑止
---（`round_trips` / `wakes`）だけで、どれもインメモリのみ。Neovim が落ちればワーカーチャットも
---道連れなので、`pending-resume.json` のような永続化に意味がない。
local M = {}

local notify = require("vibing.core.utils.notify")
local MessageQueue = require("vibing.application.chat.message_queue")

local AUGROUP = "VibingCompletionNotifier"
local DEFAULT_MAX_ROUND_TRIPS = 8
local DEFAULT_MAX_WAKES = 50

---edges[to_bufnr][from_bufnr] = true。
---「to_bufnr が終わったら from_bufnr に知らせる」を表す
---@type table<number, table<number, boolean>>
local edges = {}

---reported[from_bufnr][to_bufnr] = from が to に自分から送った。
---「次に from が止まったときの watchdog は冗長」を表す、エッジとは別の一時マーク
---@type table<number, table<number, boolean>>
local reported = {}

---round_trips[lo][hi] = 手動送信を挟まずに (lo, hi) の2チャット間で配達された通知の回数。
---キーは無向ペアに正規化する（lo < hi）: 止めたいのは A⇄B の往復そのものなので、方向ごとに
---分けると A→B と B→A が別々の予算を持ち、上限が実質2倍になる
---@type table<number, table<number, number>>
local round_trips = {}

---手動送信を挟まずにこの Neovim で配達を行った回数
---@type number
local wakes = 0

---@return {enabled: boolean, max_round_trips: number?, max_wakes: number?}
local function settings()
  local config = require("vibing.config").get()
  return (config.agent and config.agent.chat_notifications) or { enabled = false }
end

---無向ペアを lo < hi に正規化する
---@param a number
---@param b number
---@return number lo
---@return number hi
local function pair_of(a, b)
  if a > b then
    return b, a
  end
  return a, b
end

---@param a number
---@param b number
---@return number
local function trips_between(a, b)
  local lo, hi = pair_of(a, b)
  local partners = round_trips[lo]
  return partners and partners[hi] or 0
end

---@param a number
---@param b number
local function record_trip(a, b)
  local lo, hi = pair_of(a, b)
  round_trips[lo] = round_trips[lo] or {}
  round_trips[lo][hi] = (round_trips[lo][hi] or 0) + 1
end

---bufnr が関わるペアのカウンタを全て捨てる
---
---空になった内側のテーブルはキーごと消す。残すと `round_trips` が `next()` で真のまま0件を
---抱えることになり、`M.forget` の早期returnが以降ずっと素通りしなくなる
---@param bufnr number
local function drop_pairs_of(bufnr)
  round_trips[bufnr] = nil
  for partner, partners in pairs(round_trips) do
    partners[bufnr] = nil
    if next(partners) == nil then
      round_trips[partner] = nil
    end
  end
end

---自分宛キューを流し、配達できたぶんだけ暴走抑止のカウンタを上げる
---
---「配達したら上げる」を関数にしてあるのは、`on_response_done` に呼び出し箇所が2つあるため。
---どちらかで書き忘れると上限が黙って連鎖を止められなくなる
---@param bufnr number
---@return boolean restarted
local function drain(bufnr)
  local restarted, delivered = MessageQueue.flush(bufnr)
  if delivered then
    -- 配られた通知1件ごとに、そのペアの往復が1回進む。全体予算のほうは「起床」の数なので、
    -- 3件が1通に合流した配達でも消費は1（相手が走るターンは1本）。本文だけを配った場合も
    -- 起床は起きているので、`delivered` が空でもここは通る
    for _, done_bufnr in ipairs(delivered) do
      record_trip(bufnr, done_bufnr)
    end
    wakes = wakes + 1
  end
  return restarted
end

---bufnr が「自分の完了を待っている相手」以外の誰かの完了を待っているか
---
---`edges[*][bufnr]` は「bufnr が送信した相手が、まだ完了を返していない」を意味する。
---残っているあいだ bufnr は待ち合わせ中で、そのターン終了は完了ではなく中間停止。
---
---**自分の購読者を除くのが要点。** `on_sent` は送信のたびに送信者を受信者の購読者にするので、
---B が親 A に報告しただけでも `edges[a][b]` ができ、素直に数えると B は「A 待ち」になる。
---A は B の完了を待っているのだから、そこで B の完了を保留すると互いに待ち合って永久に
---止まる。機構は送信が報告か依頼かを区別できない（#651）が、「相手が自分の完了を待っている」
---なら少なくとも自分の停止を伝えるべき相手ではある、という向きだけは分かる。
---
---逆引きの索引は持たずに走査する。エッジ数はチャット数と同じオーダーで、`forget()` も
---同じ走査をしている。二重管理を増やすほうが、ここでは高くつく
---@param bufnr number
---@return boolean
local function is_waiting_on_others(bufnr)
  local my_subscribers = edges[bufnr] or {}
  for to_bufnr, subscribers in pairs(edges) do
    if subscribers[bufnr] ~= nil and my_subscribers[to_bufnr] == nil then
      return true
    end
  end
  return false
end

---子待ちを押しのけて親に知らせるべき止まり方か
---
---ワーカーのバッファは誰も見ていないので、質問・承認待ち・エラーで止まったまま保留すると
---誰も対応できない。
---
---読むのは `ChatBuffer:get_stop_reason()` そのもので、`chat_status` の語彙ではない。
---あちらは `responding` / `idle` を混ぜた MCP 向けの合成なので、経由すると「この2つには
---一致してはいけない」という知識をここに持つことになり、停止理由が増えたときに黙って
---「対応不要」に分類する。理由が非nilかどうかだけを見れば、増えた理由は自動的に発火側に入る。
---
---バッファが取れない場合は false（＝保留のまま）でよい。そこに至るのは既に消えたバッファで、
---`forget()` が `BufDelete` でエッジごと落としているので保留するものが残っていない
---@param bufnr number
---@return boolean
local function stopped_needing_attention(bufnr)
  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  return chat_buf ~= nil and chat_buf:get_stop_reason() ~= nil
end

---A が B に送ったことを購読として記録する
---@param from_bufnr number 送信元（通知を受け取る側）
---@param to_bufnr number 送信先（完了を監視される側）
---@return boolean subscribed ペアの往復上限・全体予算などで張らなかった場合 false
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

  -- 同じ (A, B) への複数送信は1本に畳む。A が B に3回送っても通知は1回。
  -- この判定を上限より**前**に置く: 既に張ってあるエッジは生きていて通知も届くのに、
  -- 上限に当たったという理由で「購読しなかった」と警告するのは事実に反する。
  -- 同じワーカーに複数回ブリーフを送るのは `vibing-orchestrate` の通常の手順
  if edges[to_bufnr] and edges[to_bufnr][from_bufnr] then
    return true
  end

  -- 黙って張らないと、通知が来ない理由がどこにも残らない。A→B→A→B の往復自体は正当な
  -- ユースケース（Bの質問にAが答える）なので、循環検出ではなく回数で止めている
  local trips = trips_between(from_bufnr, to_bufnr)
  local max_round_trips = cfg.max_round_trips or DEFAULT_MAX_ROUND_TRIPS
  if trips >= max_round_trips then
    notify.warn(
      string.format(
        "Chats %d and %d have gone back and forth %d times without a manual send; not subscribing. "
          .. "Send a message in either chat yourself to reset the pair.",
        from_bufnr,
        to_bufnr,
        trips
      ),
      "Chat Notifications"
    )
    return false
  end

  -- ペアカウンタが苦手な形に効く最終防壁。苦手なのは配達が多くのペアに散る形で、毎回違う相手に
  -- 配り続ける扇（どのペアも1のまま）と、長い循環（A→B→C→A は1周でどのペアも1しか進まない）。
  -- どちらが先に当たるかは形と設定値次第で、既定では3チャットの循環はペア上限が先に拾う
  -- （8周＝24配達で、予算は50に届かない）
  --
  -- **両方の上限は購読の時点でしか見ない。** 既に張られたエッジは、その配達までに他のエッジが
  -- 予算を使い切っても配られるので、上限は「その時点で生きているエッジの数」ぶんだけ超過しうる。
  -- 配達直前に見る設計にはしていない: 認可済みの通知を配達時に落とすと、オーケストレータは
  -- ワーカーの完了を黙って取りこぼす。それはこのモジュールが避けるために存在している失敗そのもので、
  -- 一度きり・有界の超過より悪い。超過しても以降の `subscribe` は拒否されるので連鎖は止まる
  local max_wakes = cfg.max_wakes or DEFAULT_MAX_WAKES
  if wakes >= max_wakes then
    notify.warn(
      string.format(
        "Chat notifications have woken chats %d times without a manual send; "
          .. "not subscribing chat %d to chat %d. Send a message in any chat yourself to reset the budget.",
        wakes,
        from_bufnr,
        to_bufnr
      ),
      "Chat Notifications"
    )
    return false
  end

  edges[to_bufnr] = edges[to_bufnr] or {}
  edges[to_bufnr][from_bufnr] = true

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

  -- 抑止マークは `edges` のためだけにある。無効ならエッジは張られないので、溜めても無駄なうえ、
  -- セッション中に有効化されたときに、無効だった間の送信が新しいエッジを誤って黙らせる
  if not settings().enabled then
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
---
---発火判定は3分岐（#639 / #640）:
---  1. 自分宛キューを流せた → この tick で自分が再稼働する → 配達もエッジ消費もしない
---  2. 自分が張った未消費のエッジが残っている → 子待ちでの停止 → 親への配達を保留
---  3. どちらでもない → 本当に止まった → watchdog として購読者へ配達
---2 の例外は `stopped_needing_attention`
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

  -- 分岐2。エッジテーブルは親子を区別しないので、判定の意味は「誰かの返事を待っている」。
  --
  -- 抑止マーク（`reported`）はここでは**使い切らない**。マークが黙らせるのは停止そのものでは
  -- なく watchdog の配達1回ぶんで、保留した停止は誰にも配達していない。ここで捨てると、
  -- 本当に止まったときの配達で「もう自分から報告した相手」を二度起こすことになる
  if is_waiting_on_others(bufnr) and not stopped_needing_attention(bufnr) then
    return
  end

  -- 抑止マークの消費は `enabled` の判定より**前**。マークは「次の停止1回ぶん」の一時状態なので、
  -- 完了を見送るときも一緒に使い切らないと、無効化を挟んだ間のマークが残り、有効化後に張り直された
  -- 正当なエッジを黙って落とす。`on_sent` が無効時にマークを立てないのと対になる配慮で、
  -- `setup()` の「実行中に設定を変えた場合も追従する」はこの経路のこと
  local suppressed = reported[bufnr] or {}
  reported[bufnr] = nil

  if not settings().enabled then
    return
  end

  local subscribers = edges[bufnr]

  if subscribers then
    -- 配達した時点で購読は消える（one-shot）。B が次に完了しても、A が改めて送っていなければ
    -- 通知は飛ばない。自分から報告済みの相手も、購読は同じように使い切る — 用件は届いている
    edges[bufnr] = nil
    for from_bufnr in pairs(subscribers) do
      if not suppressed[from_bufnr] and vim.api.nvim_buf_is_valid(from_bufnr) then
        MessageQueue.enqueue_notification(from_bufnr, bufnr)
      end
    end
    for from_bufnr in pairs(subscribers) do
      drain(from_bufnr)
    end
  end
end

---人間が手動送信した。上限カウンタにとってはこれが起点になる
---
---`on_response_done` と対になるイベント入口で、名前もそちらに合わせてある。「bufnr の状態を
---消す」関数ではなく「人間が動いた、その帰結をモジュールが決める」関数なので、bufnr を取りつつ
---全体予算まで触るのが正しい形になる。
---
---ペアは bufnr が関わるものを全て落とす。人間が A に介入した以上、A を通る連鎖はもう無人では
---ない。全体予算は「無人で走り続けている」ことへの防壁なので、その前提が切れたら残す意味がない。
---
---代償として、全体予算は1本しかないので無関係な2つのオーケストレーションが同じ予算を分け合う:
---一方が使い切れば他方も止まり、一方への `<CR>` が他方の予算も戻す。連結成分ごとに持つ設計は
---`subscribe` の時点で成分が決まらない（新しい相手への扇はどのペアにも属さない）ため採らない
---@param bufnr number
function M.on_manual_send(bufnr)
  drop_pairs_of(bufnr)
  wakes = 0
end

---バッファが消えたので関連する購読・キューを捨てる
---@param bufnr number
function M.forget(bufnr)
  MessageQueue.forget(bufnr)

  -- autocmdはパターン無しで登録しているので、エディタ内のどのバッファを閉じても走る。
  -- 既定（無効）では状態が空のまま、全テーブルの走査だけが通常の編集操作ごとに起きる。
  -- キューは自分の空振りを自分で弾くので、ここで見るのは自分の状態だけ
  if not (next(edges) or next(round_trips) or next(reported)) then
    return
  end

  edges[bufnr] = nil
  reported[bufnr] = nil
  drop_pairs_of(bufnr)

  -- 空になった内側のテーブルはキーごと消す。残すと `next(edges)` / `next(reported)` が真のまま
  -- 0件を抱えることになり、上の早期returnが以降ずっと素通りしなくなる。この関数はパターン無しの
  -- `BufDelete` から走るので、それは通常の編集操作のたびに全走査が復活するということ
  for other, subscribers in pairs(edges) do
    subscribers[bufnr] = nil
    if next(subscribers) == nil then
      edges[other] = nil
    end
  end
  for other, targets in pairs(reported) do
    targets[bufnr] = nil
    if next(targets) == nil then
      reported[other] = nil
    end
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
