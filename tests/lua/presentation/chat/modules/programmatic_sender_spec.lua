local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local ChatBuffer = require("vibing.presentation.chat.buffer")
local view = require("vibing.presentation.chat.view")

describe("ProgrammaticSender.send", function()
  local original_get_chat_buffer
  local bufnr
  local fake

  before_each(function()
    original_get_chat_buffer = view.get_chat_buffer
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "---", "vibing.nvim: true", "---", "" })

    fake = { responding = false, sends = 0, result = true }
    view.get_chat_buffer = function(target)
      if target ~= bufnr then
        return nil
      end
      return {
        is_responding = function()
          return fake.responding
        end,
        send_message = function()
          fake.sends = fake.sends + 1
          return fake.result
        end,
      }
    end
  end)

  after_each(function()
    view.get_chat_buffer = original_get_chat_buffer
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  ---@return number
  local function user_headers()
    local count = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:match("User") then
        count = count + 1
      end
    end
    return count
  end

  ---@return string[]
  local function buffer_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  it("writes the delivery header it was handed instead of a plain User section", function()
    ProgrammaticSender.send(bufnr, "done", nil, { kind = "Report", from = ".vibing/chat/worker.md" })

    local lines = buffer_lines()
    assert.is_true(
      vim.tbl_contains(lines, "## Report <!-- unsent from .vibing/chat/worker.md -->"),
      table.concat(lines, "\n")
    )
  end)

  it("fills the empty unsent section a finished turn left behind", function()
    -- ターンが終わるたび `add_user_section()` が空の未送信セクションを置く。人間はそこに
    -- 打ち込むが、配達はその下にもう1つ足していたので、配達されたターンの上に空の
    -- `## User` が毎回取り残されていた
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "## User <!-- unsent -->", "", "" })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" })

    local headers = vim.tbl_filter(function(line)
      return line:match("^## ")
    end, buffer_lines())
    assert.same({ "## Request <!-- unsent -->" }, headers)
  end)

  it("keeps a trailing section that still has something in it", function()
    -- 承認プロンプトや質問の選択肢は同じ未送信セクションに描かれる。空でないものを
    -- 落とすと、ユーザーが答えようとしていた選択肢が配達のたびに消える
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "## User <!-- unsent -->", "", "1. PostgreSQL", "" })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" })

    local lines = buffer_lines()
    assert.is_true(vim.tbl_contains(lines, "1. PostgreSQL"), table.concat(lines, "\n"))
  end)

  it("replaces a trailing section with something in it when asked to", function()
    -- 承認への代理応答（`approval_delegate`）だけがこれを渡す。そこでは承認プロンプトそのものが
    -- 「答える対象」なので、残すと答え終わったプロンプトがバッファに永久に居座る
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
      "## User <!-- unsent -->",
      "",
      "⚠️  Tool approval required",
      "",
      "1. allow_once - Allow this execution only",
      "",
    })

    ProgrammaticSender.send(bufnr, "1. allow_once - Allow this execution only", nil, {
      kind = "Request",
      from = ".vibing/chat/orchestrator.md",
    }, { replace_unsent = true })

    local lines = buffer_lines()
    assert.is_false(vim.tbl_contains(lines, "⚠️  Tool approval required"), table.concat(lines, "\n"))

    local headers = vim.tbl_filter(function(line)
      return line:match("^## ")
    end, lines)
    assert.same({ "## Request <!-- unsent from .vibing/chat/orchestrator.md -->" }, headers)
  end)

  it("leaves an already-committed trailing section alone even with replace_unsent", function()
    -- 「未送信ヘッダーが見つかるまで遡る」実装だと、送信済みセクションを飛び越えて上のほうの
    -- 未送信セクションを消しうる。末尾から最初に当たったヘッダーだけを見る
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
      "## User <!-- 2026-09-03 10:00:00 -->",
      "",
      "already sent",
      "",
    })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" }, { replace_unsent = true })

    local lines = buffer_lines()
    assert.is_true(vim.tbl_contains(lines, "already sent"), table.concat(lines, "\n"))
  end)

  it("refuses a chat that is already responding, before touching the buffer", function()
    -- 追加してから巻き戻すのではなく追加する前に断る。`ChatBuffer:send_message()` は
    -- 応答中なら黙って return するので、先に append すると送られない `## User` が残り、
    -- 次にユーザーが<CR>したときの本文に化ける
    fake.responding = true
    local before = user_headers()

    assert.has_error(function()
      ProgrammaticSender.send(bufnr, "hello")
    end)
    assert.equals(0, fake.sends)
    assert.equals(before, user_headers())
  end)

  it("reports success only when the chat actually took the message", function()
    assert.is_true(ProgrammaticSender.send(bufnr, "hello").success)

    fake.result = false
    assert.is_false(ProgrammaticSender.send(bufnr, "hello").success)
  end)

  it("rejects an empty message and a non-chat buffer", function()
    assert.has_error(function()
      ProgrammaticSender.send(bufnr, "   ")
    end)
    assert.has_error(function()
      ProgrammaticSender.send(bufnr + 9999, "hello")
    end)
  end)

  it("appends a timestamped Notice without sending an LLM request", function()
    local path = vim.fn.tempname() .. ".md"
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "## User <!-- unsent -->", "", "" })

    local result = ProgrammaticSender.append_notice(bufnr, "background work finished")

    assert.is_true(result.success)
    assert.equals(0, fake.sends)
    local lines = buffer_lines()
    assert.is_true(vim.tbl_contains(lines, "background work finished"), table.concat(lines, "\n"))
    assert.is_true(vim.tbl_contains(lines, "## User <!-- unsent -->"), table.concat(lines, "\n"))
    local notices = vim.tbl_filter(function(line)
      return line:match("^## Notice <!%-%- %d%d%d%d%-%d%d%-%d%d")
    end, lines)
    assert.equals(1, #notices, table.concat(lines, "\n"))
    vim.fn.delete(path)
  end)

  describe("delivering into a responding chat", function()
    --- "Do not push into a chat that is responding" is right for every ordinary delivery: the send
    --- would leave an unsent section behind and cancel the turn on its way. #778 creates the one
    --- exception — a chat holding a blocked hook is responding by that definition, and the answer
    --- to that hook is precisely what it is waiting for.
    local Pending = require("vibing.infrastructure.rpc.pending_approvals")

    before_each(function()
      fake.responding = true
      Pending._reset()
    end)

    after_each(function()
      Pending._reset()
    end)

    it("refuses an ordinary delivery", function()
      local ok, err = pcall(ProgrammaticSender.send, bufnr, "anything")

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("already responding", 1, true), tostring(err))
      assert.equals(0, fake.sends)
    end)

    it("accepts an answer to a hook that is actually blocked", function()
      Pending.open({ request_id = "req-1", chat_bufnr = bufnr, tool = "Bash" })

      local result = ProgrammaticSender.send(bufnr, "1. allow_once", nil, nil, {
        answers_blocked_approval = "req-1",
      })

      assert.is_true(result.success)
      assert.equals(1, fake.sends)
    end)

    it("refuses an answer naming a request nothing is blocked on", function()
      -- The exemption asks the registry, not the caller. A prompt still drawn from a killed turn
      -- is answered as a *new* turn, so letting it through here would cancel the live one.
      local ok, err = pcall(ProgrammaticSender.send, bufnr, "1. allow_once", nil, nil, {
        answers_blocked_approval = "req-gone",
      })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("already responding", 1, true), tostring(err))
      assert.equals(0, fake.sends)
    end)
  end)

  describe("answering a blocked question from another chat", function()
    --- #788 reopened, for questions, the hole #778 closed for approvals. A chat waiting on a
    --- question is `is_responding()` by the same definition, so the orchestrator the worker-stopped
    --- notification tells to use `nvim_chat_send_message` was refused by the guard above — it could
    --- see `asked_question` and could not answer it.
    local PendingQuestions = require("vibing.infrastructure.rpc.pending_questions")

    ---@param request_id string
    local function open_question(request_id)
      PendingQuestions.open({
        request_id = request_id,
        chat_bufnr = bufnr,
        respond = function() end,
      })
    end

    before_each(function()
      fake.responding = true
      PendingQuestions._reset()
    end)

    after_each(function()
      PendingQuestions._reset()
    end)

    it("accepts the answer while a question is actually blocked", function()
      open_question("q-1")

      local result = ProgrammaticSender.send(bufnr, "the second one", nil, nil, {
        answers_blocked_question = true,
      })

      assert.is_true(result.success)
      assert.equals(1, fake.sends)
    end)

    it("refuses the same send once nothing is waiting for it", function()
      -- The human answered in the buffer between the caller reading `asked_question` and the send
      -- arriving. The flag is the caller's claim; the registry is the fact, and the fact wins.
      local ok, err = pcall(ProgrammaticSender.send, bufnr, "the second one", nil, nil, {
        answers_blocked_question = true,
      })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("already responding", 1, true), tostring(err))
      assert.equals(0, fake.sends)
    end)

    it("refuses a delivery that does not claim to be the answer", function()
      -- A blocked question must not open the chat to every sender. auto_compact's `/compact`,
      -- auto_resume's re-send and `append_notice` all reach `validate`, and any of them getting
      -- through would be eaten by `_answer_pending_question` as the answer.
      open_question("q-1")

      local ok, err = pcall(ProgrammaticSender.send, bufnr, "unrelated report")

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("already responding", 1, true), tostring(err))
      assert.equals(0, fake.sends)
    end)

    it("reports a blocked question without being asked to send anything", function()
      -- `nvim_chat_send_message`'s `queue_if_busy` branch reads this *before* validate, because
      -- queueing an answer is worse than refusing it: it sits for `question_wait_sec` and is
      -- delivered as a new turn only after the question it answers has expired.
      assert.is_false(ProgrammaticSender.has_blocked_question(bufnr))
      open_question("q-1")
      assert.is_true(ProgrammaticSender.has_blocked_question(bufnr))
    end)
  end)
end)

describe("ChatBuffer:add_user_section", function()
  it("does not fire VibingResponseDone on its own", function()
    -- 完了イベントは send_message() のコールバックラッパー側にある。このメソッド本体に
    -- 置くと、スラッシュコマンド経路（AIターンが1回も走っていない）からも完了が飛ぶ
    local bufnr = vim.api.nvim_create_buf(false, true)
    local chat = setmetatable({ buf = bufnr, win = nil, _chunk_parts = {} }, ChatBuffer)

    local fired = 0
    local group = vim.api.nvim_create_augroup("VibingCompletionNotifierSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "VibingResponseDone",
      callback = function()
        fired = fired + 1
      end,
    })

    chat:add_user_section()

    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.equals(0, fired)
  end)

end)
