local Config = require("vibing.config")
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local notify = require("vibing.core.utils.notify")

describe("CompletionNotifier", function()
  ---モジュールレベルの購読テーブルはspec間で共有されるので、毎回requireし直して捨てる。
  ---本番側にリセット用のAPIを生やすより、追加した状態が自動的にリセット対象になる
  local Notifier
  local MessageQueue
  local originals = {}
  local buffers = {}
  local responding = {}
  local drafts = {}
  local sends = {}
  local warnings = {}
  local send_result = { success = true }

  ---チャットバッファに見える実バッファを1つ作る
  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    return bufnr
  end

  ---@param opts table?
  local function configure(opts)
    Config.get = function()
      return { agent = { chat_notifications = vim.tbl_extend("force", { enabled = true, max_hops = 8 }, opts or {}) } }
    end
  end

  before_each(function()
    originals.get = Config.get
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.warn = notify.warn

    buffers, responding, drafts, sends, warnings = {}, {}, {}, {}, {}
    send_result = { success = true }

    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        is_responding = function()
          return responding[bufnr] == true
        end,
        extract_user_message = function()
          return drafts[bufnr]
        end,
      }
    end
    ProgrammaticSender.send = function(bufnr, message)
      table.insert(sends, { bufnr = bufnr, message = message })
      if send_result.throws then
        error("boom")
      end
      -- 実物と同じく、送信が通ればその場でターンが走り出す。`send_result.starts_turn = false` が
      -- リミット中の予約や `SendMessage.execute` の早期returnで、受理はされたがターンは
      -- 始まらなかった場合
      if send_result.success and send_result.starts_turn ~= false then
        responding[bufnr] = true
      end
      return { success = send_result.success, bufnr = bufnr }
    end
    notify.warn = function(message, title)
      table.insert(warnings, { message = message, title = title })
    end

    configure()

    -- 配達キューは別モジュールに分かれていて、そちらもモジュールレベルの状態を持つ。
    -- notifier だけ捨てても、キャッシュされたキューの滞留がspec間で持ち越される
    package.loaded["vibing.application.chat.message_queue"] = nil
    package.loaded["vibing.application.chat.completion_notifier"] = nil
    Notifier = require("vibing.application.chat.completion_notifier")
    MessageQueue = require("vibing.application.chat.message_queue")
  end)

  after_each(function()
    Config.get = originals.get
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    notify.warn = originals.warn

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("delivers to the sender when the chat it messaged finishes", function()
    local a, b = make_chat(), make_chat()

    assert.is_true(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
    assert.is_truthy(sends[1].message:find("chat buffer " .. b, 1, true))
  end)

  it("does not deliver into a chat that is still responding", function()
    -- 本改修で一番壊れやすい箇所。応答中のバッファに送ると ChatBuffer:send_message() が
    -- 「前のリクエストが実行中ならキャンセル」で進行中のターンを kill する
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(0, #sends)
  end)

  it("drains a queued notification when the sender itself finishes", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.equals(0, #sends)

    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
  end)

  it("coalesces several queued notifications into one message", function()
    local a, b, c = make_chat(), make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, b)
    Notifier.subscribe(a, c)
    Notifier.on_response_done(b)
    Notifier.on_response_done(c)

    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
    assert.is_truthy(sends[1].message:find("chat buffer " .. b, 1, true))
    assert.is_truthy(sends[1].message:find("chat buffer " .. c, 1, true))
  end)

  it("consumes the edge on delivery so a second completion is silent", function()
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
  end)

  it("notifies once even when the sender messaged the same chat repeatedly", function()
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.subscribe(a, b)
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
  end)

  it("delivers to every chat subscribed to the same worker", function()
    local a1, a2, b = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a1, b)
    Notifier.subscribe(a2, b)
    Notifier.on_response_done(b)

    local targets = { [sends[1].bufnr] = true, [sends[2].bufnr] = true }
    assert.equals(2, #sends)
    assert.is_true(targets[a1])
    assert.is_true(targets[a2])
  end)

  it("drops the subscription instead of erroring when the sender buffer is gone", function()
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    vim.api.nvim_buf_delete(a, { force = true })

    assert.has_no.errors(function()
      Notifier.on_response_done(b)
    end)
    assert.equals(0, #sends)
  end)

  it("neither subscribes nor delivers when the feature is disabled", function()
    configure({ enabled = false })
    local a, b = make_chat(), make_chat()

    assert.is_false(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)

    assert.equals(0, #sends)
  end)

  it("refuses a chat subscribing to itself", function()
    local a = make_chat()

    assert.is_false(Notifier.subscribe(a, a))
  end)

  it("stops the chain at max_hops and says so instead of going quiet", function()
    configure({ max_hops = 1 })
    local a, b = make_chat(), make_chat()

    -- 1ホップ目: 購読して配達されると、A の深さが 1 になる
    assert.is_true(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)
    assert.equals(1, #sends)

    -- 2ホップ目は上限に当たる。黙って張らないと通知が来ない理由がどこにも残らない
    assert.is_false(Notifier.subscribe(a, b))
    assert.equals(1, #warnings)
    assert.equals("Chat Notifications", warnings[1].title)
  end)

  it("does not warn about an edge it already holds when at the hop limit", function()
    -- 同じワーカーに複数回ブリーフを送るのは通常の手順。既に張ってあるエッジは生きていて
    -- 通知も届くので、上限に当たったからといって「購読しなかった」と警告するのは事実に反する
    configure({ max_hops = 0 })
    local a, b = make_chat(), make_chat()

    -- 上限0でも、既存エッジがあれば黙って成功を返す
    Notifier.subscribe(a, b)
    assert.equals(1, #warnings, "the first subscribe is genuinely refused")

    configure({ max_hops = 8 })
    assert.is_true(Notifier.subscribe(a, b))
    configure({ max_hops = 0 })

    assert.is_true(Notifier.subscribe(a, b))
    assert.equals(1, #warnings, "re-sending to an already-subscribed chat must not warn")
  end)

  it("resets the hop count on a manual send", function()
    configure({ max_hops = 1 })
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.is_false(Notifier.subscribe(a, b))

    Notifier.reset_depth(a)

    assert.is_true(Notifier.subscribe(a, b))
  end)

  it("forgets a buffer's edges and queue in both directions", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    Notifier.forget(b)
    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(0, #sends)
  end)

  it("tells the sender that finishing is not the same as succeeding", function()
    -- `idle` はエラー終了でも、質問でターンが死んだときでも、ツール承認待ちでも通る。
    -- 成否の判定を通知側でやると chat_status と同じ罠を踏むので、判断は受け取り側に委ねる
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.is_truthy(sends[1].message:find("no request is in flight", 1, true))
    assert.is_truthy(sends[1].message:find("do not start aggregating yet", 1, true))
  end)

  it("keeps the notification queued when delivery fails", function()
    -- エッジは配達時点で消費済みなので、失敗した通知を捨てると二度と再現しない
    local a, b = make_chat(), make_chat()
    send_result = { success = false }

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.equals(1, #sends)
    assert.equals(1, #warnings)

    send_result = { success = true }
    Notifier.on_response_done(a)

    assert.equals(2, #sends)
  end)

  it("keeps the notification queued when delivery throws", function()
    local a, b = make_chat(), make_chat()
    send_result = { throws = true }

    Notifier.subscribe(a, b)
    assert.has_no.errors(function()
      Notifier.on_response_done(b)
    end)

    send_result = { success = true }
    Notifier.on_response_done(a)

    assert.equals(a, sends[#sends].bufnr)
  end)

  it("does not overwrite a draft the user is still typing", function()
    -- 配達は新しい `## User` を足すので、下書きは送られないまま宙に浮く
    local a, b = make_chat(), make_chat()
    drafts[a] = "half-written question"

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(0, #sends)

    -- ユーザーがその下書きを送れば、そのターンの完了で取りこぼさず流れる
    drafts[a] = nil
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
  end)

  it("holds the edge through a turn that only exists to restart the chat", function()
    -- A → B → C の2段。C の完了通知が B に滞留している間に、B の中間ターン（「C に送った、
    -- 待つ」だけのターン）が終わるケース
    local a, b, c = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.subscribe(b, c)

    responding[b] = true
    Notifier.on_response_done(c)
    assert.equals(0, #sends, "B is responding, so C's completion stays queued")

    responding[b] = false
    Notifier.on_response_done(b)

    assert.equals(1, #sends, "only B's own queue drains; A is not woken mid-flight")
    assert.equals(b, sends[1].bufnr)

    -- B の2ターン目（本命の報告）が終わって初めて A に配達される
    Notifier.on_response_done(b)

    assert.equals(2, #sends)
    assert.equals(a, sends[2].bufnr)
  end)

  it("does not hold the edge for a delivery that started no turn", function()
    -- `ChatBuffer:send_message()` は「リクエストとして扱ったか」を返すので、リミット中の予約でも
    -- `SendMessage.execute` がアダプタ未設定・セッション競合で降りた場合でも true になる。
    -- 後者はストリームを張らず `VibingResponseDone` も来ないので、これを再稼働と読むと
    -- エッジは二度と配達されずに残る
    local a, b, c = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.subscribe(b, c)

    responding[b] = true
    Notifier.on_response_done(c)

    responding[b] = false
    send_result = { success = true, starts_turn = false }
    Notifier.on_response_done(b)

    assert.equals(2, #sends, "B's queue drains, and A is told because B did not restart")
    assert.equals(b, sends[1].bufnr)
    assert.equals(a, sends[2].bufnr)
  end)

  it("still notifies subscribers when the queued delivery was refused", function()
    -- 配達が拒否された = そのバッファは再稼働しないので、購読者への配達を見送る理由がない
    local a, b, c = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.subscribe(b, c)

    responding[b] = true
    Notifier.on_response_done(c)

    responding[b] = false
    drafts[b] = "the user is typing in the middle chat"
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
  end)

  it("never lowers the hop count when a shallow edge is delivered late", function()
    configure({ max_hops = 2 })
    local a, b, c = make_chat(), make_chat(), make_chat()

    -- 先に浅い時点のエッジを張っておき、配達だけ遅らせる
    Notifier.subscribe(a, c)

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b) -- depth[a] = 1
    responding[a] = false -- 起こされた A のターンが終わる
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b) -- depth[a] = 2
    responding[a] = false

    -- 深さ0で張られた c のエッジがここで配達されても、カウンタは戻らない
    Notifier.on_response_done(c)
    assert.is_false(Notifier.subscribe(a, b))
  end)

  it("drains a queued message even when watchdog notifications are disabled", function()
    -- `chat_notifications.enabled` が gate するのは「読みに行け」を自動で飛ばすかどうか。
    -- `queue_if_busy` は呼び出し側が明示的に出した配達要求なので、設定に従わせると
    -- 通知を切っている環境でワーカーの報告が黙って消える
    configure({ enabled = false })
    local a, b = make_chat(), make_chat()
    responding[a] = true

    assert.is_true(MessageQueue.enqueue_message(a, b, "the migration is done"))
    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
    assert.is_truthy(sends[1].message:find("the migration is done", 1, true))
  end)

  it("carries the sender's body rather than telling the reader to go and fetch it", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    MessageQueue.enqueue_message(a, b, "found the leak in parser.lua")
    responding[a] = false
    Notifier.on_response_done(a)

    assert.is_truthy(sends[1].message:find("found the leak in parser.lua", 1, true))
    assert.is_truthy(sends[1].message:find("chat buffer " .. b, 1, true))
  end)

  it("coalesces queued messages and completion notices into one turn", function()
    local a, b, c = make_chat(), make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, c)
    Notifier.on_response_done(c)
    MessageQueue.enqueue_message(a, b, "worker b reporting in")

    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
    assert.is_truthy(sends[1].message:find("worker b reporting in", 1, true))
    assert.is_truthy(sends[1].message:find("chat buffer " .. c, 1, true))
  end)

  it("drops the watchdog edge once the watched chat has reported for itself", function()
    -- B が A に自分から送った以上、「B が止まった、読みに行け」は同じ用件の二度目になる
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_sent(b, a)
    Notifier.on_response_done(b)

    assert.equals(0, #sends)

    -- A が改めて B に送れば張り直される
    assert.is_true(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)
    assert.equals(1, #sends)
  end)

  it("drops a completion notice already queued about the chat that then reported", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    MessageQueue.enqueue_message(a, b, "here is what I found")
    Notifier.on_sent(b, a)

    responding[a] = false
    Notifier.on_response_done(a)

    assert.equals(1, #sends)
    assert.is_truthy(sends[1].message:find("here is what I found", 1, true))
    assert.is_falsy(sends[1].message:find("finished responding", 1, true))
  end)

  it("keeps the subscription alive when the report turns out to be an intermediate one", function()
    -- A → B → C。B が「C に投げた、待つ」を A に伝えてから、C の報告で再稼働する。
    -- 送信の時点では、それが最終報告か途中経過かは機構には分からない。エッジを消してしまうと
    -- B の本命の報告が終わっても A には二度と通知が来ない（#638 が直したのと同じ取りこぼし）
    local a, b, c = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.subscribe(b, c)

    -- B が A に途中経過を送る（A は応答中なので積まれるだけ）
    responding[a] = true
    Notifier.on_sent(b, a)
    MessageQueue.enqueue_message(a, b, "dispatched to C, waiting")

    -- C が先に終わり、B のキューに滞留する
    responding[b] = true
    Notifier.on_response_done(c)

    -- B の中間ターンが終わる: 自分のキューで再稼働するので A には知らせない
    responding[b] = false
    Notifier.on_response_done(b)
    assert.equals(b, sends[#sends].bufnr, "only B's own queue drains; A is not woken mid-flight")

    -- B の本命の報告ターンが終わる。購読は生きていなければならない
    responding[a] = false
    responding[b] = false
    Notifier.on_response_done(b)

    -- A には B の途中経過と「B が止まった」が1ターンにまとまって届く
    assert.equals(a, sends[#sends].bufnr)
    assert.is_truthy(sends[#sends].message:find("dispatched to C, waiting", 1, true))
    assert.is_truthy(sends[#sends].message:find("chat buffer " .. b, 1, true))
  end)

  it("records no suppression while the feature is disabled", function()
    -- 無効な間はエッジが張られないので印は無駄なうえ、途中で有効化されたときに
    -- 無効だった間の送信が新しいエッジを誤って黙らせる
    configure({ enabled = false })
    local a, b = make_chat(), make_chat()

    Notifier.on_sent(b, a)

    configure({ enabled = true })
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
  end)

  it("does not carry a suppression mark across a spell of the feature being disabled", function()
    -- マークは「次の停止1回ぶん」の一時状態。無効化を挟んだ完了で使い切らないと残り、
    -- 有効化後に張り直された正当なエッジを黙って落とす — このリポジトリが繰り返し
    -- 防いでいる「黙って消える」そのものになる
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_sent(b, a)

    -- B が止まる前に無効化される。完了は購読者に配らないが、印はここで使い切られる
    configure({ enabled = false })
    Notifier.on_response_done(b)
    assert.equals(0, #sends)

    -- 有効化して改めて購読を張り直す。古い印に黙らされてはいけない
    configure({ enabled = true })
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
  end)

  it("suppresses only the one stop that follows the report", function()
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_sent(b, a)

    Notifier.on_response_done(b)
    assert.equals(0, #sends, "A heard from B directly, so the watchdog is redundant")

    -- 購読は使い切られている。改めて送らなければ次の完了でも黙ったまま
    Notifier.on_response_done(b)
    assert.equals(0, #sends)
  end)

  it("does not raise the hop count for a queued message", function()
    -- 直接送信は今も hop 予算の対象外で、`queue_if_busy` はその同じ送信が遅れて届くだけ。
    -- ペア単位の往復カウンタは #644 の担当
    configure({ max_hops = 1 })
    local a, b = make_chat(), make_chat()
    responding[a] = true

    MessageQueue.enqueue_message(a, b, "a report")
    responding[a] = false
    Notifier.on_response_done(a)
    assert.equals(1, #sends)

    responding[a] = false
    assert.is_true(Notifier.subscribe(a, b), "the delivery must not have spent A's hop budget")
  end)

  describe("setup", function()
    it("delivers through the VibingResponseDone autocmd", function()
      local a, b = make_chat(), make_chat()
      Notifier.setup()
      Notifier.subscribe(a, b)

      vim.api.nvim_exec_autocmds("User", { pattern = "VibingResponseDone", data = { bufnr = b } })

      assert.equals(1, #sends)
      assert.equals(a, sends[1].bufnr)
    end)

    it("ignores an event with no bufnr instead of erroring", function()
      Notifier.setup()

      assert.has_no.errors(function()
        vim.api.nvim_exec_autocmds("User", { pattern = "VibingResponseDone" })
      end)
    end)
  end)
end)
