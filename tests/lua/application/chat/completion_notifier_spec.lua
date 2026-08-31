local Config = require("vibing.config")
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local notify = require("vibing.core.utils.notify")

describe("CompletionNotifier", function()
  ---モジュールレベルの購読テーブルはspec間で共有されるので、毎回requireし直して捨てる。
  ---本番側にリセット用のAPIを生やすより、追加した状態が自動的にリセット対象になる
  local Notifier
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
        -- 分岐2の例外（質問・承認待ち・エラー）は `chat_status` 経由で読まれる。
        -- そちらは実物を通すので、材料になるこのメソッドだけ差し替える
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

    configure()

    package.loaded["vibing.application.chat.completion_notifier"] = nil
    Notifier = require("vibing.application.chat.completion_notifier")
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
  end)

  describe("a sent message consumes the watchdog edge pointing the other way", function()
    it("does not also wake the recipient with a watchdog for the sender", function()
      -- B が A に報告したあと B のターンが終わると、A は報告と watchdog で二度起こされる
      local a, b = make_chat(), make_chat()

      Notifier.subscribe(a, b) -- A→B のブリーフ: B が止まったら A に知らせる
      Notifier.on_message_sent(b, a) -- B→A の報告

      Notifier.on_response_done(b)

      assert.equals(0, #sends, "A already has B's own report")
    end)

    it("still subscribes the sender to the chat it messaged", function()
      local a, b = make_chat(), make_chat()

      Notifier.on_message_sent(a, b)
      Notifier.on_response_done(b)

      assert.equals(1, #sends)
      assert.equals(a, sends[1].bufnr)
    end)

    it("drops a watchdog that was queued but not yet delivered", function()
      local a, b = make_chat(), make_chat()
      responding[a] = true

      Notifier.subscribe(a, b)
      Notifier.on_response_done(b) -- A が応答中なので積まれるだけ
      assert.equals(0, #sends)

      Notifier.on_message_sent(b, a) -- B 自身の報告が A に届いたので、積んである分は用済み

      responding[a] = false
      Notifier.on_response_done(a)

      -- A 自身の完了は B に配達される（B が A に送った＝B は返事を待っている）。
      -- 落ちているべきなのは「A を B について起こす」ほうだけ
      for _, sent in ipairs(sends) do
        assert.not_equals(a, sent.bufnr)
      end
    end)

    it("leaves another chat's subscription to the same sender alone", function()
      local a1, a2, b = make_chat(), make_chat(), make_chat()

      Notifier.subscribe(a1, b)
      Notifier.subscribe(a2, b)
      Notifier.on_message_sent(b, a1) -- A1 のエッジだけが消費される

      Notifier.on_response_done(a1) -- A1 が応じて B の待ち合わせが解ける
      responding[b] = false
      sends = {}

      Notifier.on_response_done(b)

      assert.equals(1, #sends)
      assert.equals(a2, sends[1].bufnr)
    end)
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
