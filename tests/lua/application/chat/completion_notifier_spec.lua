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

  it("never lowers the hop count when a shallow edge is delivered late", function()
    configure({ max_hops = 2 })
    local a, b, c = make_chat(), make_chat(), make_chat()

    -- 先に浅い時点のエッジを張っておき、配達だけ遅らせる
    Notifier.subscribe(a, c)

    Notifier.subscribe(a, b)
    Notifier.on_response_done(b) -- depth[a] = 1
    Notifier.subscribe(a, b)
    Notifier.on_response_done(b) -- depth[a] = 2

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
