-- `nvim_chat_send_message` のRPCハンドラ。
--
-- ここでしか再現しない相互作用がひとつある: 完了通知の購読と、実際に送れたかどうかの関係。
-- 購読を送信より前に張ると、送信が弾かれたときに「送っていないメッセージについて相手が
-- 終わった、読みに行け」という通知だけが後から届く。`completion_notifier` 単体テストにも
-- `programmatic_sender` 単体テストにも、この経路は現れない。

local Message = require("vibing.infrastructure.rpc.handlers.message")
local Config = require("vibing.config")
local view = require("vibing.presentation.chat.view")
local OrchestrationLink = require("vibing.application.chat.orchestration_link")
local ChatLocator = require("vibing.application.chat.chat_locator")

describe("rpc handlers.message.send_message", function()
  local Notifier
  local originals = {}
  local buffers = {}
  local chats = {}

  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "---", "vibing.nvim: true", "---", "" })
    table.insert(buffers, bufnr)
    chats[bufnr] = { responding = false, accepts = true, sends = 0 }
    return bufnr
  end

  ---@param max_concurrent number 0で無制限（既定）
  local function configure(max_concurrent)
    Config.get = function()
      return {
        agent = {
          chat_notifications = { enabled = true, max_round_trips = 8, max_wakes = 50 },
          orchestration = { max_concurrent = max_concurrent },
        },
      }
    end
  end

  before_each(function()
    originals.get = Config.get
    originals.get_chat_buffer = view.get_chat_buffer
    originals.list_chat_buffers = view.list_chat_buffers
    originals.link = OrchestrationLink.link
    originals.open = ChatLocator.open

    buffers, chats = {}, {}

    configure(0)
    view.get_chat_buffer = function(bufnr)
      local chat = chats[bufnr]
      if not chat then
        return nil
      end
      return {
        is_responding = function()
          return chat.responding
        end,
        extract_user_message = function()
          return nil
        end,
        get_stop_reason = function()
          return chat.stop_reason
        end,
        send_message = function()
          chat.sends = chat.sends + 1
          return chat.accepts
        end,
      }
    end
    view.list_chat_buffers = function()
      local open = {}
      for _, bufnr in ipairs(buffers) do
        open[bufnr] = view.get_chat_buffer(bufnr)
      end
      return open
    end
    -- リンクの書き込みはこのspecの主題ではない（ディスクに触るのも避ける）
    OrchestrationLink.link = function()
      return true, nil
    end

    package.loaded["vibing.application.chat.message_queue"] = nil
    package.loaded["vibing.application.chat.completion_notifier"] = nil
    Notifier = require("vibing.application.chat.completion_notifier")
  end)

  after_each(function()
    Config.get = originals.get
    view.get_chat_buffer = originals.get_chat_buffer
    view.list_chat_buffers = originals.list_chat_buffers
    OrchestrationLink.link = originals.link
    ChatLocator.open = originals.open

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("subscribes the sender once the message is actually taken", function()
    local from, to = make_chat(), make_chat()

    Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = from })
    Notifier.on_response_done(to)

    assert.equals(1, chats[from].sends, "the sender should be woken by the completion")
  end)

  it("leaves no subscription when the target is busy and the send is refused", function()
    local from, to = make_chat(), make_chat()
    chats[to].responding = true

    assert.has_error(function()
      Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = from })
    end)

    -- 送信が通らなかったのだから、宛先がいま走っているターンを終えても通知は届かない
    chats[to].responding = false
    Notifier.on_response_done(to)

    assert.equals(0, chats[from].sends)
  end)

  it("leaves no subscription when the chat silently declines the message", function()
    local from, to = make_chat(), make_chat()
    chats[to].accepts = false

    Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = from })
    Notifier.on_response_done(to)

    assert.equals(0, chats[from].sends)
  end)

  it("sends without recording anything when from_bufnr is omitted", function()
    local to = make_chat()

    local result = Message.send_message({ bufnr = to, message = "do the thing" })

    assert.is_true(result.success)
    assert.equals(1, chats[to].sends)
  end)

  it("forwards task to OrchestrationLink.link for the immediate delivery path (#696 follow-up)", function()
    local from, to = make_chat(), make_chat()
    local captured
    OrchestrationLink.link = function(f, t, task)
      captured = { from = f, to = t, task = task }
      return true, nil
    end

    Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = from, task = "PR #688 -- review" })

    assert.same({ from = from, to = to, task = "PR #688 -- review" }, captured)
  end)

  it("addresses the target by file_path", function()
    local to = make_chat()
    ChatLocator.open = function(file_path)
      assert.equals(".vibing/chat/worker.md", file_path)
      return to
    end

    local result = Message.send_message({ file_path = ".vibing/chat/worker.md", message = "do the thing" })

    assert.is_true(result.success)
    assert.equals(to, result.bufnr)
    assert.equals(1, chats[to].sends)
  end)

  it("subscribes the sender when the target was named by file_path", function()
    -- 購読は解決後の bufnr で張る。パスのまま渡すと `completion_notifier` は
    -- 「number ではない」で黙って false を返し、通知が来ない理由がどこにも残らない
    local from, to = make_chat(), make_chat()
    ChatLocator.open = function()
      return to
    end

    Message.send_message({ file_path = "worker.md", message = "do the thing", from_bufnr = from })
    Notifier.on_response_done(to)

    assert.equals(1, chats[from].sends)
  end)

  it("refuses a call that names the target twice instead of picking one", function()
    local to = make_chat()
    ChatLocator.open = function()
      error("should not resolve a path when bufnr was given too")
    end

    assert.has_error(function()
      Message.send_message({ bufnr = to, file_path = "worker.md", message = "do the thing" })
    end)
    assert.equals(0, chats[to].sends)
  end)

  it("refuses a call that names no target at all", function()
    assert.has_error(function()
      Message.send_message({ message = "do the thing" })
    end)
  end)

  it("refuses bufnr 0 rather than sending into whichever chat the user is looking at", function()
    -- `nvim_get_buffer` advertises 0 as "the current buffer", so a model will try it here too.
    -- Resolving it would append a `## User` and start a turn in the chat that happens to be
    -- focused — the same misdelivery the both-arguments refusal exists to prevent.
    assert.has_error(function()
      Message.send_message({ bufnr = 0, message = "do the thing" })
    end)
  end)

  it("treats an explicit null file_path as absent, not as a second target", function()
    -- `vim.json.decode` turns a JSON null into `vim.NIL`, which is truthy in Lua
    local to = make_chat()

    local result = Message.send_message({ bufnr = to, file_path = vim.NIL, message = "do the thing" })

    assert.is_true(result.success)
    assert.equals(1, chats[to].sends)
  end)

  it("refuses a from_bufnr that names no buffer instead of silently dropping the link", function()
    -- 典型は Neovim 再起動を跨いで会話履歴から使い回された番号（#661）。黙って流すと
    -- リンクも購読も無いまま送信だけが成功し、訂正できる唯一の相手（呼び出し元）に何も伝わらない
    local to = make_chat()

    assert.has_error(function()
      Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = 99999 })
    end)
    assert.equals(0, chats[to].sends)
  end)

  it("refuses a from_bufnr that names a buffer that is not a chat", function()
    local to = make_chat()
    local plain = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, plain)

    assert.has_error(function()
      Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = plain })
    end)
    assert.equals(0, chats[to].sends)
  end)

  it("refuses a stale from_bufnr before queueing, not after", function()
    local to = make_chat()
    chats[to].responding = true

    assert.has_error(function()
      Message.send_message({ bufnr = to, message = "report", from_bufnr = 99999, queue_if_busy = true })
    end)

    -- 積まれていないことまで確かめる: 宛先が完了してもこのメッセージは配達されない
    chats[to].responding = false
    Notifier.on_response_done(to)
    assert.equals(0, chats[to].sends)
  end)

  it("treats an explicit null from_bufnr as absent, not as a stale number", function()
    local to = make_chat()

    local result = Message.send_message({ bufnr = to, message = "do the thing", from_bufnr = vim.NIL })

    assert.is_true(result.success)
    assert.equals(1, chats[to].sends)
  end)

  it("queues instead of refusing when the target is busy and the caller asked for it", function()
    local from, to = make_chat(), make_chat()
    chats[to].responding = true

    local result =
      Message.send_message({ bufnr = to, message = "my report", from_bufnr = from, queue_if_busy = true })

    assert.is_true(result.success)
    assert.is_true(result.queued)
    assert.equals(0, chats[to].sends, "nothing may be appended while the target is streaming")

    chats[to].responding = false
    Notifier.on_response_done(to)

    assert.equals(1, chats[to].sends)
  end)

  it("subscribes on the queued path too, so the sender still hears the target stop", function()
    local from, to = make_chat(), make_chat()
    chats[to].responding = true

    Message.send_message({ bufnr = to, message = "my report", from_bufnr = from, queue_if_busy = true })

    chats[to].responding = false
    Notifier.on_response_done(to)

    assert.equals(1, chats[from].sends)
  end)

  it("queues a target that was named by file_path", function()
    -- 宛先の解決は `queue_if_busy` の判定より前。パスのまま積むと、キューは配達先を
    -- 引けないバッファ番号として持つことになる
    local from, to = make_chat(), make_chat()
    chats[to].responding = true
    ChatLocator.open = function()
      return to
    end

    local result = Message.send_message({
      file_path = "worker.md",
      message = "my report",
      from_bufnr = from,
      queue_if_busy = true,
    })

    assert.is_true(result.queued)
    assert.equals(to, result.bufnr)

    chats[to].responding = false
    Notifier.on_response_done(to)

    assert.equals(1, chats[to].sends)
  end)

  it("still refuses a target that waiting cannot make sendable", function()
    -- `queue_if_busy` が引き受けるのは「応答中」だけ。空メッセージや実在しないバッファは
    -- いくら待っても解けないので、従来どおりのエラーにする
    local to = make_chat()

    assert.has_error(function()
      Message.send_message({ bufnr = to, message = "  ", queue_if_busy = true })
    end)
  end)

  it("refuses a chat queueing a message to itself", function()
    -- `validate` は応答中を理由に断っていたので、この経路ができるまでは起こりえなかった。
    -- 積むと自分の配達で自分が再稼働し、hop 予算の抑止も効かない
    local a = make_chat()
    chats[a].responding = true

    assert.has_error(function()
      Message.send_message({ bufnr = a, message = "note to self", from_bufnr = a, queue_if_busy = true })
    end)

    chats[a].responding = false
    Notifier.on_response_done(a)

    assert.equals(0, chats[a].sends)
  end)

  it("refuses a send that would exceed the concurrency limit, naming the escape hatch", function()
    configure(1)
    local from, to, busy = make_chat(), make_chat(), make_chat()
    chats[busy].responding = true

    local ok, err = pcall(Message.send_message, { bufnr = to, message = "do the thing", from_bufnr = from })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("queue_if_busy", 1, true))
    assert.equals(0, chats[to].sends)
  end)

  it("queues instead of refusing when the limit is reached and queue_if_busy was passed", function()
    -- 宛先自身は idle。待てば解けるのは「宛先が応答中」だけではない
    configure(1)
    local from, to, busy = make_chat(), make_chat(), make_chat()
    chats[busy].responding = true

    local result = Message.send_message({
      bufnr = to,
      message = "do the thing",
      from_bufnr = from,
      queue_if_busy = true,
    })

    assert.is_true(result.queued)
    assert.equals(0, chats[to].sends)

    chats[busy].responding = false
    Notifier.on_response_done(busy)

    assert.equals(1, chats[to].sends, "the freed slot is what delivers it")
  end)

  it("does not wake a chat twice when the answer it was waiting for already arrived", function()
    -- B が A に質問し、A が答える。答えが届いた以上「A が止まった、読みに行け」は同じ用件の二度目
    local a, b = make_chat(), make_chat()

    Message.send_message({ bufnr = a, message = "which schema?", from_bufnr = b })
    Message.send_message({ bufnr = b, message = "use the second one", from_bufnr = a })
    local delivered = chats[b].sends

    Notifier.on_response_done(a)

    assert.equals(delivered, chats[b].sends)
  end)
end)
