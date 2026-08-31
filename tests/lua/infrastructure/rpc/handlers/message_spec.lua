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

  before_each(function()
    originals.get = Config.get
    originals.get_chat_buffer = view.get_chat_buffer
    originals.link = OrchestrationLink.link
    originals.open = ChatLocator.open

    buffers, chats = {}, {}

    Config.get = function()
      return { agent = { chat_notifications = { enabled = true, max_hops = 8 } } }
    end
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
        send_message = function()
          chat.sends = chat.sends + 1
          return chat.accepts
        end,
      }
    end
    -- リンクの書き込みはこのspecの主題ではない（ディスクに触るのも避ける）
    OrchestrationLink.link = function()
      return true, nil
    end

    package.loaded["vibing.application.chat.completion_notifier"] = nil
    Notifier = require("vibing.application.chat.completion_notifier")
  end)

  after_each(function()
    Config.get = originals.get
    view.get_chat_buffer = originals.get_chat_buffer
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
end)
