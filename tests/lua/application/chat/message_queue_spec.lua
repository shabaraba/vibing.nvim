-- 配達キューそのものの責務。購読・hop 予算との組み合わせは completion_notifier_spec が見る。
--
-- ここでしか現れないのはリンク書き込みのタイミングで、`orchestration_link.link` は宛先バッファの
-- frontmatter を直接編集する。積む条件が「宛先が応答中」なので、積んだ時点で書くとその宛先の
-- ストリーミングと競合する。配達直前まで遅らせているのはそのため。
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local OrchestrationLink = require("vibing.application.chat.orchestration_link")
local notify = require("vibing.core.utils.notify")

describe("MessageQueue", function()
  local Queue
  local originals = {}
  local buffers = {}
  local responding = {}
  local sends = {}
  local links = {}
  local warnings = {}

  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.link = OrchestrationLink.link
    originals.warn = notify.warn

    buffers, responding, sends, links, warnings = {}, {}, {}, {}, {}

    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        is_responding = function()
          return responding[bufnr] == true
        end,
        extract_user_message = function()
          return nil
        end,
      }
    end
    ProgrammaticSender.send = function(bufnr, message)
      table.insert(sends, { bufnr = bufnr, message = message })
      responding[bufnr] = true
      return { success = true, bufnr = bufnr }
    end
    -- 本物はディスクに触るので差し替える。順序の観測だけがここの目的
    OrchestrationLink.link = function(from, to)
      table.insert(links, { from = from, to = to, sends_so_far = #sends })
      return true, nil
    end
    notify.warn = function(message, title)
      table.insert(warnings, { message = message, title = title })
    end

    package.loaded["vibing.application.chat.message_queue"] = nil
    Queue = require("vibing.application.chat.message_queue")
  end)

  after_each(function()
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    OrchestrationLink.link = originals.link
    notify.warn = originals.warn

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("writes the orchestration link at delivery, not while the recipient is responding", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "a report")
    assert.equals(0, #links, "nothing may touch A's frontmatter while it is streaming")

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #links)
    assert.equals(b, links[1].from)
    assert.equals(a, links[1].to)
    assert.equals(0, links[1].sends_so_far, "the link must precede the send, as on the direct path")
  end)

  it("writes one link per sender however many messages that sender queued", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "first")
    Queue.enqueue_message(a, b, "second")

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #links)
  end)

  it("writes no link for a message that named no sender", function()
    local a = make_chat()

    Queue.enqueue_message(a, nil, "from nobody in particular")
    Queue.flush(a)

    assert.equals(0, #links)
    assert.equals(1, #sends)
  end)

  it("delivers every queued message in one turn, in the order they were queued", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "FIRST-BODY")
    Queue.enqueue_message(a, b, "SECOND-BODY")

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #sends)
    local first = sends[1].message:find("FIRST-BODY", 1, true)
    local second = sends[1].message:find("SECOND-BODY", 1, true)
    assert.is_truthy(first)
    assert.is_truthy(second)
    assert.is_true(first < second)
  end)

  it("reports whether the delivery actually started a turn", function()
    local a = make_chat()
    Queue.enqueue_message(a, nil, "body")

    assert.is_true(Queue.flush(a))
  end)

  it("keeps the queue when the recipient is responding and delivers nothing", function()
    local a = make_chat()
    responding[a] = true

    Queue.enqueue_message(a, nil, "body")
    assert.is_false(Queue.flush(a))
    assert.equals(0, #sends)

    responding[a] = false
    assert.is_true(Queue.flush(a))
    assert.equals(1, #sends)
  end)

  it("warns rather than silently dropping a completion notice past the cap", function()
    -- 通知側は呼ぶ前にエッジを消費しているので、黙って捨てると二度と再現しない
    local a, b = make_chat(), make_chat()
    responding[a] = true

    for _ = 1, 20 do
      Queue.enqueue_message(a, nil, "filler")
    end
    Queue.enqueue_notification(a, b, 0)

    assert.equals(1, #warnings)
    assert.equals("Chat Delivery", warnings[1].title)
  end)

  it("does not count a repeat notice about the same chat against the cap", function()
    -- 「止まった、読みに行け」は同じ相手について何度あっても伝えることは1つ
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_notification(a, b, 0)
    Queue.enqueue_notification(a, b, 0)

    responding[a] = false
    Queue.flush(a)

    local _, count = sends[1].message:gsub("chat buffer " .. b, "")
    assert.equals(1, count)
  end)

  it("forgets a deleted buffer as a recipient and as a sender", function()
    local a, b, c = make_chat(), make_chat(), make_chat()
    responding[a] = true
    responding[c] = true

    Queue.enqueue_message(a, b, "from b")
    Queue.enqueue_message(c, b, "also from b")

    Queue.forget(b)

    responding[a], responding[c] = false, false
    Queue.flush(a)
    Queue.flush(c)

    assert.equals(0, #sends)
  end)

  it("counts messages rather than claiming that many chats sent them", function()
    -- 1つのワーカーからの2件を「2つのチャットから」と言うと、読み手は出どころを取り違える
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "first")
    Queue.enqueue_message(a, b, "second")

    responding[a] = false
    Queue.flush(a)

    assert.is_falsy(sends[1].message:find("2 other chats", 1, true))
    assert.is_truthy(sends[1].message:find("2 messages", 1, true))
  end)

  it("refuses an empty body rather than queueing something that can never be sent", function()
    -- 積んでしまうと配達時に `ProgrammaticSender` が弾き、そのときにはもう送信元に伝える先がない
    local a = make_chat()

    local ok, err = Queue.enqueue_message(a, nil, "   ")

    assert.is_false(ok)
    assert.is_truthy(err)
  end)
end)
