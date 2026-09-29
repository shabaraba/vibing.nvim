-- 予約送信: 応答中に積んだ本文を、ターンが終わった瞬間に改行 join の1リクエストで送る。
-- ChatBuffer は偽物で、ここで見るのは「いつ送るか・送らないならどこに置くか」だけ
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local notify = require("vibing.core.utils.notify")

describe("Reservations", function()
  local Reservations
  local originals = {}
  local buffers = {}
  local chats = {}
  local sends = {}

  ---@return number bufnr
  ---@return table chat 偽の ChatBuffer。フィールドを書き換えて状態を作る
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    local chat = {
      responding = false,
      prompts = false,
      cancelled = false,
      stop_reason = nil,
      draft = nil,
    }
    function chat:is_responding()
      return self.responding
    end
    function chat:has_unanswered_prompts()
      return self.prompts
    end
    function chat:was_cancelled()
      return self.cancelled
    end
    function chat:get_stop_reason()
      return self.stop_reason
    end
    function chat:extract_user_message()
      return self.draft
    end
    chats[bufnr] = chat
    return bufnr, chat
  end

  ---@param bufnr number
  ---@return string
  local function buffer_text(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  before_each(function()
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.warn = notify.warn
    originals.info = notify.info

    buffers, chats, sends = {}, {}, {}

    view.get_chat_buffer = function(bufnr)
      return chats[bufnr]
    end
    ProgrammaticSender.send = function(bufnr, message)
      table.insert(sends, { bufnr = bufnr, message = message })
      chats[bufnr].responding = true
      return { success = true, bufnr = bufnr }
    end
    notify.warn = function() end
    notify.info = function() end

    package.loaded["vibing.application.chat.reservations"] = nil
    Reservations = require("vibing.application.chat.reservations")
  end)

  after_each(function()
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    notify.warn = originals.warn
    notify.info = originals.info

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("holds every reservation while responding and sends them joined by newlines in one request", function()
    local bufnr, chat = make_chat()
    chat.responding = true

    assert.is_true(Reservations.add(bufnr, "first"))
    assert.is_true(Reservations.add(bufnr, "second"))
    assert.is_true(Reservations.add(bufnr, "third"))
    assert.equals(0, #sends, "nothing may be sent into a responding chat")
    assert.equals(3, Reservations.count(bufnr))

    chat.responding = false
    assert.equals("sent", Reservations.flush(bufnr))

    assert.equals(1, #sends, "all reservations travel as one request")
    assert.equals("first\nsecond\nthird", sends[1].message)
    assert.equals(0, Reservations.count(bufnr))
  end)

  it("keeps reservations per chat buffer", function()
    local a, chat_a = make_chat()
    local b, chat_b = make_chat()
    chat_a.responding, chat_b.responding = true, true

    Reservations.add(a, "for a")
    Reservations.add(b, "for b")

    chat_a.responding = false
    Reservations.flush(a)

    assert.equals(1, #sends)
    assert.equals(a, sends[1].bufnr)
    assert.equals("for a", sends[1].message)
    assert.same({ "for b" }, Reservations.list(b), "b's reservation must wait for b's own turn")
  end)

  it("sends at once when the chat is already idle (the turn ended while the input was open)", function()
    local bufnr = make_chat()

    Reservations.add(bufnr, "late")

    assert.equals(1, #sends)
    assert.equals("late", sends[1].message)
  end)

  it("sends on the turn-finished event, one tick later", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "queued")

    chat.responding = false
    Reservations.on_response_done(bufnr)
    assert.equals(0, #sends, "must not start a turn from inside _finish_turn")

    vim.wait(100, function()
      return #sends > 0
    end)
    assert.equals(1, #sends)
  end)

  it("refuses an empty reservation", function()
    local bufnr, chat = make_chat()
    chat.responding = true

    local ok, err = Reservations.add(bufnr, "   ")
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.equals(0, Reservations.count(bufnr))
  end)

  it("does not send after a cancelled turn and leaves the text in the unsent section", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "one")
    Reservations.add(bufnr, "two")

    chat.responding = false
    chat.cancelled = true
    assert.equals("parked", Reservations.flush(bufnr))

    assert.equals(0, #sends)
    assert.equals(0, Reservations.count(bufnr))
    local text = buffer_text(bufnr)
    assert.is_truthy(text:find("<!-- unsent -->", 1, true), text)
    assert.is_truthy(text:find("one\ntwo", 1, true), text)
  end)

  it("does not send after a turn that ended in an error", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "retry this")

    chat.responding = false
    chat.stop_reason = "error"
    assert.equals("parked", Reservations.flush(bufnr))

    assert.equals(0, #sends)
    assert.is_truthy(buffer_text(bufnr):find("retry this", 1, true))
  end)

  it("waits while a prompt is waiting in the unsent section", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "after the prompt")

    chat.responding = false
    chat.prompts = true
    assert.equals("waiting", Reservations.flush(bufnr))
    assert.equals(0, #sends)
    assert.equals(1, Reservations.count(bufnr), "the reservation is kept, not dropped")

    chat.prompts = false
    assert.equals("sent", Reservations.flush(bufnr))
  end)

  it("waits while the unsent section holds the user's own draft", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "reserved")

    chat.responding = false
    chat.draft = "half-written"
    assert.equals("waiting", Reservations.flush(bufnr))
    assert.equals(0, #sends)
    assert.equals(1, Reservations.count(bufnr))
  end)

  it("keeps the text in the unsent section when the send fails", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "important")
    ProgrammaticSender.send = function()
      error("boom")
    end

    chat.responding = false
    assert.equals("parked", Reservations.flush(bufnr))
    assert.is_truthy(buffer_text(bufnr):find("important", 1, true))
  end)

  it("clear drops the reservations and reports how many", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "a")
    Reservations.add(bufnr, "b")

    assert.equals(2, Reservations.clear(bufnr))
    chat.responding = false
    assert.equals("none", Reservations.flush(bufnr))
    assert.equals(0, #sends)
  end)

  it("forgets a wiped buffer's reservations", function()
    local bufnr, chat = make_chat()
    chat.responding = true
    Reservations.add(bufnr, "a")

    Reservations.forget(bufnr)
    assert.equals(0, Reservations.count(bufnr))
  end)
end)

describe("ChatBuffer reservation state", function()
  local ChatBuffer = require("vibing.presentation.chat.buffer")

  it("records a cancel only when a turn is running", function()
    local chat = ChatBuffer:new({})
    chat:_mark_cancelled()
    assert.is_false(chat:was_cancelled(), "cancelling an idle chat is not a cancelled turn")

    chat._is_sending = true
    chat:_mark_cancelled()
    assert.is_true(chat:was_cancelled())
  end)

  it("treats a prompt drawn in the unsent section as unanswered", function()
    local chat = ChatBuffer:new({})
    chat.buf = vim.api.nvim_create_buf(false, true)
    assert.is_false(chat:has_unanswered_prompts())

    chat._prompts_rendered_unsent = true
    assert.is_true(chat:has_unanswered_prompts())
    vim.api.nvim_buf_delete(chat.buf, { force = true })
  end)
end)
