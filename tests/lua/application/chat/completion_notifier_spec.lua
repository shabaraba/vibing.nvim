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
  local stop_reasons = {}
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
  ---@param orchestration table? 並列度上限（既定は無制限で、既存の挙動と同じ）
  local function configure(opts, orchestration)
    Config.get = function()
      return {
        agent = {
          chat_notifications = vim.tbl_extend(
            "force",
            { enabled = true, max_round_trips = 8, max_wakes = 50 },
            opts or {}
          ),
          orchestration = orchestration or { max_concurrent = 0 },
        },
      }
    end
  end

  before_each(function()
    originals.get = Config.get
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.warn = notify.warn
    originals.list_chat_buffers = view.list_chat_buffers

    buffers, responding, drafts, sends, warnings = {}, {}, {}, {}, {}
    stop_reasons = {}
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
        -- 分岐2の例外（質問・承認待ち・エラー）は、`chat_status` の語彙を経由せず
        -- これを直接読む（`stop_reason_of`）。停止理由が増えたときに
        -- 分類漏れで黙って「対応不要」になるのを避けるため
        get_stop_reason = function()
          return stop_reasons[bufnr]
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
    -- 並列度上限が「いま何本走っているか」を数える先。上限を設定しないspecでは参照されない
    view.list_chat_buffers = function()
      local chats = {}
      for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          chats[bufnr] = view.get_chat_buffer(bufnr)
        end
      end
      return chats
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
    view.list_chat_buffers = originals.list_chat_buffers

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

  it("subscribes but delivers nothing for an ordinary stop when the feature is disabled", function()
    -- エッジは配達の前提であって配達そのものではない。無効な環境でも張っておかないと、
    -- 自力では抜けられない止まり方（下のテスト群）を伝える先が無くなる
    configure({ enabled = false })
    local a, b = make_chat(), make_chat()

    assert.is_true(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)

    assert.equals(0, #sends)
  end)

  -- 質問・承認待ち・エラーで止まったチャットは、ターンごと kill されるか失敗して終わるので
  -- 自分では報告できない。外から誰かが動かさないかぎり二度と走らないのに、唯一の経路が
  -- オプトインの裏にあると、既定の設定ではツリーが黙って止まる
  for _, reason in ipairs({ "asked_question", "waiting_approval", "error" }) do
    it("delivers a " .. reason .. " stop even when the feature is disabled", function()
      configure({ enabled = false })
      local a, b = make_chat(), make_chat()

      Notifier.subscribe(a, b)
      stop_reasons[b] = reason
      Notifier.on_response_done(b)

      assert.equals(1, #sends)
      assert.equals(a, sends[1].bufnr)
      assert.is_truthy(
        sends[1].message:find("status: " .. reason, 1, true),
        "the notice names what the chat is stuck on: " .. sends[1].message
      )
    end)
  end

  it("ignores the report suppression mark when the stop needs attention", function()
    -- 抑止マークは「同じ用件を自分から報告済み」を意味するが、報告のあとで承認待ちに落ちたのなら
    -- それは報告に載っていない新しい事実。分岐2の例外と揃える
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_sent(b, a)
    stop_reasons[b] = "waiting_approval"

    Notifier.on_response_done(b)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
  end)

  it("refuses a chat subscribing to itself", function()
    local a = make_chat()

    assert.is_false(Notifier.subscribe(a, a))
  end)

  it("stops a pair at max_round_trips and says so instead of going quiet", function()
    configure({ max_round_trips = 1 })
    local a, b = make_chat(), make_chat()

    -- 1往復目: 購読して配達されると、(a, b) のカウンタが 1 になる
    assert.is_true(Notifier.subscribe(a, b))
    Notifier.on_response_done(b)
    assert.equals(1, #sends)

    -- 2往復目は上限に当たる。黙って張らないと通知が来ない理由がどこにも残らない
    assert.is_false(Notifier.subscribe(a, b))
    assert.equals(1, #warnings)
    assert.equals("Chat Notifications", warnings[1].title)
  end)

  it("counts a pair in both directions as one counter", function()
    -- 止めたいのは A⇄B の往復そのもの。方向ごとに分けると A→B と B→A が別々の予算を持ち、
    -- 上限が実質2倍になる
    configure({ max_round_trips = 1 })
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.equals(1, #sends)

    -- B が A に投げ返す向きも、同じペアの予算を見る
    assert.is_false(Notifier.subscribe(b, a))
  end)

  it("does not stop an orchestrator receiving from many workers", function()
    -- #644 の本題。旧実装は「起こされた回数」のグローバルカウンタだったので、子N人からの
    -- 完了通知を受けるだけで正当なオーケストレータが上限に当たっていた
    configure({ max_round_trips = 1 })
    local a = make_chat()
    local workers = {}

    for i = 1, 5 do
      workers[i] = make_chat()
      assert.is_true(Notifier.subscribe(a, workers[i]), "worker " .. i .. " must be subscribable")
      Notifier.on_response_done(workers[i])
      responding[a] = false
    end

    assert.equals(5, #sends)
    assert.equals(0, #warnings)
  end)

  it("stops a fan that never repeats a pair at max_wakes", function()
    -- ペア上限をすり抜ける形（毎回違う相手に配り続ける）に効く最終防壁
    configure({ max_round_trips = 8, max_wakes = 2 })
    local a = make_chat()

    for _ = 1, 2 do
      local worker = make_chat()
      assert.is_true(Notifier.subscribe(a, worker))
      Notifier.on_response_done(worker)
      responding[a] = false
    end
    assert.equals(2, #sends)

    assert.is_false(Notifier.subscribe(a, make_chat()))
    assert.equals(1, #warnings)
    assert.equals("Chat Notifications", warnings[1].title)
  end)

  it("does not warn about an edge it already holds when at the limit", function()
    -- 同じワーカーに複数回ブリーフを送るのは通常の手順。既に張ってあるエッジは生きていて
    -- 通知も届くので、上限に当たったからといって「購読しなかった」と警告するのは事実に反する
    configure({ max_round_trips = 0 })
    local a, b = make_chat(), make_chat()

    -- 上限0でも、既存エッジがあれば黙って成功を返す
    Notifier.subscribe(a, b)
    assert.equals(1, #warnings, "the first subscribe is genuinely refused")

    configure({ max_round_trips = 8 })
    assert.is_true(Notifier.subscribe(a, b))
    configure({ max_round_trips = 0 })

    assert.is_true(Notifier.subscribe(a, b))
    assert.equals(1, #warnings, "re-sending to an already-subscribed chat must not warn")
  end)

  it("resets the pair counter on a manual send", function()
    configure({ max_round_trips = 1 })
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.is_false(Notifier.subscribe(a, b))

    Notifier.on_manual_send(a)

    assert.is_true(Notifier.subscribe(a, b))
  end)

  it("resets the whole-tree budget on a manual send too", function()
    -- 全体予算は「無人で走り続けている」ことへの防壁なので、人間が連鎖のどこかに入れば
    -- その前提が切れる。手動送信したのが予算を使い切ったチャットである必要はない
    configure({ max_wakes = 1 })
    local a, b, other = make_chat(), make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    responding[a] = false
    assert.is_false(Notifier.subscribe(a, make_chat()))

    Notifier.on_manual_send(other)

    assert.is_true(Notifier.subscribe(a, make_chat()))
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

  it("tells the sender that stopping is not the same as succeeding", function()
    -- `idle` はエラー終了でも、質問でターンが死んだときでも、ツール承認待ちでも通る。
    -- 成否の判定を通知側でやると chat_status と同じ罠を踏むので、判断は受け取り側に委ねる。
    -- 規約（#643）ではワーカーは終わったら自分から報告するので、ここに載るのは報告なしの停止
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.is_truthy(sends[1].message:find("do not treat its task as done", 1, true))
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

  describe("holding the edge while a chat waits on the chats it messaged", function()
    it("holds the parent's notification for the whole dispatch-and-wait window", function()
      -- #638 が拾えなかった側の順序。末端 C が中間 B のディスパッチターンより**後**に
      -- 終わるのが通常（ディスパッチは数秒、末端の作業は数分）で、そのとき B のキューは
      -- 空なので分岐1では止まらない。分岐2 が見るのは `edges[c][b]` の存在そのもの
      local a, b, c = make_chat(), make_chat(), make_chat()

      Notifier.subscribe(a, b)
      Notifier.subscribe(b, c)

      Notifier.on_response_done(b) -- B のディスパッチターンが終わる。C はまだ走っている
      assert.equals(0, #sends, "A is not woken mid-chain")

      Notifier.on_response_done(c) -- C 完了 → B へ配達、B 再稼働
      assert.equals(1, #sends)
      assert.equals(b, sends[1].bufnr)

      responding[b] = false
      Notifier.on_response_done(b) -- B が本当に止まる
      assert.equals(2, #sends)
      assert.equals(a, sends[2].bufnr, "the edge survived to B's real completion")
    end)

    -- ワーカーのバッファは誰も見ていないので、保留したままだと誰も対応できない。
    -- 判定は「停止理由が非nilか」なので、理由が増えれば自動的にこちら側に入る
    for _, reason in ipairs({ "asked_question", "waiting_approval", "error" }) do
      it("fires anyway when the waiting chat stopped on " .. reason, function()
        local a, b, c = make_chat(), make_chat(), make_chat()

        Notifier.subscribe(a, b)
        Notifier.subscribe(b, c)
        stop_reasons[b] = reason

        Notifier.on_response_done(b)

        assert.equals(1, #sends)
        assert.equals(a, sends[1].bufnr)
      end)
    end

    it("keeps the report suppression mark across a held completion", function()
      -- 抑止マークが黙らせるのは watchdog の配達1回ぶんで、停止1回ぶんではない。保留は
      -- 誰にも配達していないので、ここで使い切ると B が本当に止まったときに、既に自分から
      -- 報告済みの A を二度起こす
      local a, b, c = make_chat(), make_chat(), make_chat()

      Notifier.subscribe(a, b) -- A→B のブリーフ
      Notifier.subscribe(b, c) -- B→C のディスパッチ。B は C 待ちになる
      Notifier.on_sent(b, a) -- B が A に自分から報告した

      Notifier.on_response_done(b) -- 分岐2で保留。マークは温存される
      assert.equals(0, #sends)

      Notifier.on_response_done(c) -- C 完了で B の待ち合わせが解ける
      responding[b] = false
      sends = {}

      Notifier.on_response_done(b) -- B が本当に止まる

      for _, sent in ipairs(sends) do
        assert.not_equals(a, sent.bufnr, "A already had B's own report")
      end
    end)
  end)

  it("drops a deleted buffer's pair counters", function()
    -- Neovim は閉じたバッファの番号を別のバッファに使い回す。残しておくと、無関係な新しい
    -- チャットが最初の送信でいきなり上限に当たる
    configure({ max_round_trips = 1 })
    local a, b = make_chat(), make_chat()

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)
    assert.is_false(Notifier.subscribe(a, b))

    Notifier.forget(b)

    assert.is_true(Notifier.subscribe(a, b))
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
    assert.is_falsy(sends[1].message:find("stopped without reporting back", 1, true))
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

  it("records the suppression mark while the feature is disabled", function()
    -- 本文の配達は設定に依らないので、無効な間の `on_sent` も「A は B から直接聞いた」という
    -- 事実そのもの。印を立てないと、有効化したあとの最初の停止で A が同じ用件で二度起こされる
    configure({ enabled = false })
    local a, b = make_chat(), make_chat()

    Notifier.on_sent(b, a)

    configure({ enabled = true })
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b)

    assert.equals(0, #sends)
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

  it("does not advance the pair counter for a queued message", function()
    -- ペアカウンタが数えるのは watchdog 通知の配達。本文は送信元のモデルが明示的に送った
    -- もので、`on_sent` 経由で `subscribe` の判定を既に通っている。しかも即配達の経路は
    -- キューを通らないので、ここで数えると「宛先がたまたま応答中だったか」で消費が変わる
    configure({ max_round_trips = 1 })
    local a, b = make_chat(), make_chat()
    responding[a] = true

    MessageQueue.enqueue_message(a, b, "a report")
    responding[a] = false
    Notifier.on_response_done(a)
    assert.equals(1, #sends)

    responding[a] = false
    assert.is_true(Notifier.subscribe(a, b), "the delivery must not have spent the pair's budget")
  end)

  it("spends the tree-wide budget for a queued message even so", function()
    -- ペアには乗らないが起床は起きている。全体予算が数えるのは「無人でターンが1本走った」
    -- ことなので、本文だけの配達もここには乗る
    configure({ max_wakes = 1 })
    local a, b = make_chat(), make_chat()
    responding[a] = true

    MessageQueue.enqueue_message(a, b, "a report")
    responding[a] = false
    Notifier.on_response_done(a)
    assert.equals(1, #sends)

    assert.is_false(Notifier.subscribe(a, make_chat()))
  end)

  it("still delivers an edge that was authorized before the budget ran out", function()
    -- 上限は購読の時点でしか見ない。認可済みの通知を配達時に落とすと、オーケストレータは
    -- ワーカーの完了を黙って取りこぼす — このモジュールが避けるために存在している失敗そのもの。
    -- 代償として、上限は「その時点で生きているエッジの数」ぶんだけ超過しうる
    configure({ max_wakes = 1 })
    local a, b, c = make_chat(), make_chat(), make_chat()

    -- 予算が残っているうちに2本張る
    assert.is_true(Notifier.subscribe(a, b))
    assert.is_true(Notifier.subscribe(a, c))

    Notifier.on_response_done(b)
    responding[a] = false
    Notifier.on_response_done(c)

    assert.equals(2, #sends, "both authorized edges deliver, even though the budget allowed one")

    -- 超過しても連鎖は止まる: 以降の購読は拒否される
    responding[a] = false
    assert.is_false(Notifier.subscribe(a, make_chat()))
  end)

  describe("the concurrency limit", function()
    it("holds a delivery while the editor is at capacity and retries when a slot frees", function()
      configure(nil, { max_concurrent = 1 })
      local a, b, busy = make_chat(), make_chat(), make_chat()
      responding[busy] = true

      MessageQueue.enqueue_message(a, b, "carry on")
      Notifier.on_response_done(a)

      assert.equals(0, #sends, "the one slot is taken")

      responding[busy] = false
      Notifier.on_response_done(busy)

      assert.equals(1, #sends, "the freed slot is what retries the held delivery")
      assert.equals(a, sends[1].bufnr)
    end)

    it("does not report a chat as stopped while its own delivery is held", function()
      -- 上限で見送っただけのチャットはまだ用件を抱えている。停止として扱うと、親は
      -- 「ワーカーが止まった」と起こされ、そのあとワーカーは配達で勝手に走り出す
      configure(nil, { max_concurrent = 1 })
      local parent, a, b, busy = make_chat(), make_chat(), make_chat(), make_chat()
      responding[busy] = true

      Notifier.subscribe(parent, a)
      MessageQueue.enqueue_message(a, b, "carry on")

      Notifier.on_response_done(a)
      assert.equals(0, #sends)

      responding[busy] = false
      Notifier.on_response_done(busy)
      assert.equals(1, #sends)
      assert.equals(a, sends[1].bufnr)

      -- 購読は温存されているので、a が本当に止まったときに親へ届く
      responding[a] = false
      Notifier.on_response_done(a)

      assert.equals(2, #sends)
      assert.equals(parent, sends[2].bufnr)
    end)

    it("retries nothing when no limit is configured, so one refusal is not tried twice", function()
      -- 配達が断られる理由は上限のほかにもある（送信の失敗、ユーザーの下書き）。それらを
      -- 同じイベントで即座に試し直すのはただの二度打ちで、警告も2回出る
      local a, b = make_chat(), make_chat()
      send_result = { success = false }

      Notifier.subscribe(a, b)
      Notifier.on_response_done(b)

      assert.equals(1, #sends)
      assert.equals(1, #warnings)
    end)
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
