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
    OrchestrationLink.link = function(from, to, task)
      table.insert(links, { from = from, to = to, task = task, sends_so_far = #sends })
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

  it("forwards a queued task to OrchestrationLink.link (#696 follow-up)", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "brief", "PR #688 -- review")

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #links)
    assert.equals("PR #688 -- review", links[1].task)
  end)

  it("uses the last queued task from the same sender, not the first (latest instruction wins)", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "first", "first task")
    Queue.enqueue_message(a, b, "second", "second task")

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #links)
    assert.equals("second task", links[1].task)
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
    Queue.enqueue_notification(a, b)

    assert.equals(1, #warnings)
    assert.equals("Chat Delivery", warnings[1].title)
  end)

  it("upgrades a repeat notice to the newer stop reason", function()
    -- 合流させて1件にするのは正しいが、理由まで最初の1件に揃えると「読みに行け」だけが残り、
    -- 何で詰まっているかが落ちる。宛先が見るべきなのは現在の状態のほう
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_notification(a, b)
    Queue.enqueue_notification(a, b, "waiting_approval")

    responding[a] = false
    Queue.flush(a)

    assert.is_truthy(sends[1].message:find("status: waiting_approval", 1, true))
    local _, count = sends[1].message:gsub("chat buffer " .. b, "")
    assert.equals(1, count)
  end)

  it("does not count a repeat notice about the same chat against the cap", function()
    -- 「止まった、読みに行け」は同じ相手について何度あっても伝えることは1つ
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_notification(a, b)
    Queue.enqueue_notification(a, b)

    responding[a] = false
    Queue.flush(a)

    local _, count = sends[1].message:gsub("chat buffer " .. b, "")
    assert.equals(1, count)
  end)

  it("drops the queue of a deleted recipient", function()
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "for a")
    Queue.forget(a)

    responding[a] = false
    Queue.flush(a)

    assert.equals(0, #sends)
  end)

  it("drops a completion notice about a chat that no longer exists", function()
    -- 「あれが止まった、読みに行け」は、読みに行く先が消えた時点で意味を失う
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_notification(a, b)
    Queue.forget(b)

    responding[a] = false
    Queue.flush(a)

    assert.equals(0, #sends)
  end)

  it("still delivers a body whose sender was deleted, anonymously", function()
    -- 送信元の記録は表示とリンクのためのメタデータで、本文の届け先とは無関係。
    -- 送信元のバッファが閉じられただけで報告を捨てると、このモジュールが防ぐために
    -- 存在している「黙って消える」がそのまま起きる
    local a, b = make_chat(), make_chat()
    responding[a] = true

    Queue.enqueue_message(a, b, "the last thing B said")
    Queue.forget(b)

    responding[a] = false
    Queue.flush(a)

    assert.equals(1, #sends)
    assert.is_truthy(sends[1].message:find("the last thing B said", 1, true))
    assert.is_falsy(sends[1].message:find("chat buffer " .. b, 1, true))
    assert.equals(0, #links, "a chat that is gone must not be linked, nor warned about")
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

-- 名前を持つ（=保存先を持つ）チャットに限った永続化の面。無名バッファは
-- `file_path_of` が nil を返すので上の describe は一切ディスクに触らない。
describe("MessageQueue persistence (#697)", function()
  local Store = require("vibing.infrastructure.storage.message_queue_store")
  local Queue
  local originals = {}
  local tmp_root
  local buffers = {}
  local responding = {}
  local sends = {}

  ---@param filename string
  ---@return number bufnr, string path
  local function make_named_chat(filename)
    local path = tmp_root .. "/" .. filename
    vim.fn.writefile({ "## User <!-- unsent -->", "" }, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    table.insert(buffers, bufnr)
    return bufnr, path
  end

  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    Store.clear_cache()

    originals.get_chat_buffer = view.get_chat_buffer
    originals.attach_to_buffer = view.attach_to_buffer
    originals.send = ProgrammaticSender.send
    originals.link = OrchestrationLink.link

    buffers, responding, sends = {}, {}, {}

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
      return { success = true, bufnr = bufnr }
    end
    OrchestrationLink.link = function()
      return true, nil
    end

    package.loaded["vibing.application.chat.message_queue"] = nil
    Queue = require("vibing.application.chat.message_queue")
  end)

  after_each(function()
    view.get_chat_buffer = originals.get_chat_buffer
    view.attach_to_buffer = originals.attach_to_buffer
    ProgrammaticSender.send = originals.send
    OrchestrationLink.link = originals.link

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
    Store.clear_cache()
  end)

  it("writes a queued message to disk as soon as it is queued", function()
    local a, a_path = make_named_chat("a.md")
    responding[a] = true

    Queue.enqueue_message(a, nil, "queued while busy")

    local stored = Store.load(tmp_root)[a_path]
    assert.is_not_nil(stored)
    assert.equals("queued while busy", stored[1].body)
  end)

  it("clears the disk entry once the queue is actually delivered", function()
    local a, a_path = make_named_chat("a.md")
    responding[a] = true

    Queue.enqueue_message(a, nil, "queued while busy")
    responding[a] = false
    Queue.flush(a)

    assert.is_nil(Store.load(tmp_root)[a_path])
  end)

  it("restores a queue that outlived a Neovim restart and delivers it once idle", function()
    local a, a_path = make_named_chat("a.md")
    responding[a] = true

    assert.is_true(Queue.enqueue_message(a, nil, "queued while A was busy"))
    assert.is_not_nil(Store.load(tmp_root)[a_path], "must be on disk before the simulated restart")

    -- Simulate a Neovim restart: the module-level `pending` table is gone, but the chat file (and
    -- with it, message-queue.json) is still on disk. Nothing is "responding" any more either, since
    -- a restart kills every CLI process along with it.
    package.loaded["vibing.application.chat.message_queue"] = nil
    Queue = require("vibing.application.chat.message_queue")
    responding[a] = false

    Queue.restore(tmp_root)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
    assert.is_truthy(sends[1].message:find("queued while A was busy", 1, true))
    assert.is_nil(Store.load(tmp_root)[a_path], "delivered — must not be replayed on the next restart")
  end)

  it("carries a queued task through a simulated restart (#696 follow-up)", function()
    -- #697's persistence landed after #696's task field, so the round trip needs its own
    -- coverage: persist()/restore() must not silently drop `task` the way they would if only
    -- body/reason/from_file_path were serialized.
    local a, a_path = make_named_chat("a.md")
    local b = make_named_chat("b.md")
    responding[a] = true

    assert.is_true(Queue.enqueue_message(a, b, "brief", "PR #688 -- review, then update docs"))
    assert.is_not_nil(Store.load(tmp_root)[a_path])

    package.loaded["vibing.application.chat.message_queue"] = nil
    Queue = require("vibing.application.chat.message_queue")
    responding[a] = false

    local captured_task
    OrchestrationLink.link = function(_, _, task)
      captured_task = task
      return true, nil
    end

    Queue.restore(tmp_root)

    assert.equals("PR #688 -- review, then update docs", captured_task)
  end)

  it(
    "drops a restored notification whose stopped-chat file is gone, rather than corrupting the whole queue",
    function()
      -- A notification's bufnr identifies "the chat that stopped" and, unlike a message's sender,
      -- cannot be delivered anonymously. Restoring it as nil used to make every later flush()
      -- attempt fail (delivery_message tries to display a nil bufnr), taking every other item
      -- queued for the same recipient down with it.
      local a = make_named_chat("a.md")
      local b, b_path = make_named_chat("b.md")
      responding[a] = true

      Queue.enqueue_notification(a, b, "waiting_approval")
      Queue.enqueue_message(a, nil, "still deliverable")

      -- b's chat file is gone by the time we "restart" (deleted, or moved elsewhere).
      vim.fn.delete(b_path)

      package.loaded["vibing.application.chat.message_queue"] = nil
      Queue = require("vibing.application.chat.message_queue")
      responding[a] = false

      Queue.restore(tmp_root)

      assert.equals(1, #sends)
      assert.is_truthy(sends[1].message:find("still deliverable", 1, true))
    end
  )

  it(
    "keeps the disk entry when a restored buffer fails to attach, rather than deleting it",
    function()
      -- resolve_bufnr failing to attach (corrupt frontmatter, etc.) must read as "could not
      -- resolve this time," not "resolved to nothing." Treating it as resolved used to make
      -- restore() hand flush() an untracked bufnr, which warns and then deletes the disk entry —
      -- turning a one-time attach failure into a permanent loss.
      local a, a_path = make_named_chat("a.md")
      responding[a] = true

      assert.is_true(Queue.enqueue_message(a, nil, "queued while busy"))
      assert.is_not_nil(Store.load(tmp_root)[a_path])

      package.loaded["vibing.application.chat.message_queue"] = nil
      Queue = require("vibing.application.chat.message_queue")
      responding[a] = false
      view.get_chat_buffer = function()
        return nil
      end
      view.attach_to_buffer = function()
        return nil
      end

      Queue.restore(tmp_root)

      assert.equals(0, #sends)
      assert.is_not_nil(Store.load(tmp_root)[a_path], "must survive to be retried on the next restart")
    end
  )

  it("purges a restored entry whose destination chat file no longer exists on disk", function()
    local a_path = tmp_root .. "/gone.md"
    vim.fn.writefile({ "## User <!-- unsent -->", "" }, a_path)
    local a = vim.fn.bufadd(a_path)
    vim.fn.bufload(a)
    table.insert(buffers, a)
    responding[a] = true
    Queue.enqueue_message(a, nil, "orphaned")
    responding[a] = false

    vim.fn.delete(a_path)

    package.loaded["vibing.application.chat.message_queue"] = nil
    Queue = require("vibing.application.chat.message_queue")

    Queue.restore(tmp_root)

    assert.equals(0, #sends)
    assert.is_nil(Store.load(tmp_root)[a_path], "the chat file is gone for good; stop carrying it forward")
  end)

  it("does not persist a queue addressed to an unnamed (unsaved) chat", function()
    local a = make_chat()
    responding[a] = true

    Queue.enqueue_message(a, nil, "queued before the chat was ever saved")

    assert.same({}, Store.load(tmp_root))
  end)
end)
