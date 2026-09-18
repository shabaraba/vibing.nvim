---@diagnostic disable: undefined-field
--- A question asked through `nvim_ask_user_question` waits for a human instead of killing the turn
--- (#788).
---
--- The registry's contract is the one next door in `pending_approvals.lua`: every withheld reply is
--- eventually written, exactly once, by one of four exits. What these specs pin is the part that is
--- *not* shared — the reply is an MCP tool result rather than a `.res` file, and reaching the wait
--- limit **ends the turn** where an expiring approval deliberately does not.
local PendingQuestions = require("vibing.infrastructure.rpc.pending_questions")
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")

describe("pending questions", function()
  after_each(function()
    PendingQuestions._reset()
  end)

  --- @return table replies every result the entry was answered with, in order
  local function open(request_id, extra)
    local replies = {}
    local entry = vim.tbl_extend("force", {
      request_id = request_id,
      chat_bufnr = 1,
      questions = {},
      respond = function(result)
        table.insert(replies, result)
      end,
    }, extra or {})
    PendingQuestions.open(entry)
    return replies
  end

  describe("every reply is owed", function()
    it("answers the human's text back to the waiting call", function()
      local replies = open("q-1")

      assert.is_true(PendingQuestions.resolve("q-1", { status = "answered", answer = "option B" }))
      assert.equals(1, #replies)
      assert.equals("answered", replies[1].status)
      assert.equals("option B", replies[1].answer)
    end)

    it("replies exactly once, however many exits reach the same call", function()
      -- The whole point of the registry. Two writes to one MCP reply is a protocol violation; none
      -- at all is a CLI blocked inside a tool call until its own idle timeout.
      local replies = open("q-1")

      assert.is_true(PendingQuestions.resolve("q-1", { status = "answered", answer = "first" }))
      assert.is_false(PendingQuestions.resolve("q-1", { status = "answered", answer = "second" }))
      assert.is_false(PendingQuestions.expire("q-1"))
      assert.equals(0, PendingQuestions.resolve_for_chat(1, "chat went away"))
      assert.equals(0, PendingQuestions.resolve_all("nvim exited"))

      assert.equals(1, #replies)
      assert.equals("first", replies[1].answer)
    end)

    it("drops the entry even when the reply itself fails", function()
      -- The MCP server dies with the CLI it serves, so writing can fail at any point in the wait.
      -- Holding the entry open afterwards would make every later sweep report work it cannot do.
      PendingQuestions.open({
        request_id = "q-1",
        chat_bufnr = 1,
        questions = {},
        respond = function()
          error("socket is gone")
        end,
      })

      assert.is_true(PendingQuestions.resolve("q-1", { status = "answered", answer = "x" }))
      assert.is_nil(PendingQuestions.get("q-1"))
    end)

    it("reports the chat going away as unanswered, not as an answer", function()
      local replies = open("q-1")

      assert.equals(1, PendingQuestions.resolve_for_chat(1, "the chat went away"))
      assert.equals("unanswered", replies[1].status)
      assert.equals("the chat went away", replies[1].reason)
    end)

    it("answers every waiting call when Neovim exits", function()
      local a = open("q-1")
      local b = open("q-2", { chat_bufnr = 2 })

      assert.equals(2, PendingQuestions.resolve_all("nvim exited"))
      assert.equals("unanswered", a[1].status)
      assert.equals("unanswered", b[1].status)
      assert.equals(0, PendingQuestions.count())
    end)

    it("does not leave the previous owner waiting when one id is reused", function()
      local replies = open("q-1")
      open("q-1")

      assert.equals(1, #replies)
      assert.equals("unanswered", replies[1].status)
    end)
  end)

  describe("reaching the wait limit", function()
    it("reports a non-answer rather than an error", function()
      -- An error is what a model retries, and retrying this one re-asks the question -- so the user
      -- comes back to two copies of a prompt they were already looking at.
      local replies = open("q-1")

      assert.is_true(PendingQuestions.expire("q-1"))
      assert.equals("unanswered", replies[1].status)
      assert.is_nil(replies[1].error)
      assert.is_truthy(replies[1].reason:find("did not answer", 1, true))
    end)

    it("says the user may still answer, and not to re-ask", function()
      -- The wording is the only thing standing between "nobody answered" and the model asking the
      -- same question again immediately.
      local replies = open("q-1")
      PendingQuestions.expire("q-1")

      assert.is_truthy(replies[1].reason:find("may still", 1, true))
      assert.is_truthy(replies[1].reason:lower():find("do not ask the same question", 1, true))
    end)

    it("replies before it runs the callback that ends the turn", function()
      -- Same ordering as `pending_approvals.expire`, and load-bearing for the same reason: a killed
      -- CLI can no longer be the thing that stops waiting, so the reply has to be written while the
      -- process is still alive.
      local order = {}
      PendingQuestions.open({
        request_id = "q-1",
        chat_bufnr = 1,
        questions = {},
        respond = function()
          table.insert(order, "replied")
        end,
        on_timeout = function()
          table.insert(order, "turn ended")
        end,
      })

      PendingQuestions.expire("q-1")
      assert.same({ "replied", "turn ended" }, order)
    end)

    it("still replies when the callback throws", function()
      local replies = open("q-1", {
        on_timeout = function()
          error("drawing blew up")
        end,
      })

      assert.is_true(PendingQuestions.expire("q-1"))
      assert.equals(1, #replies)
    end)
  end)

  describe("listing", function()
    it("gives one chat's waiting questions oldest first", function()
      open("q-2")
      open("q-1")

      local list = PendingQuestions.list_for_chat(1)
      assert.equals(2, #list)
      -- Same `opened_at` in a fast test, so the tie-break by id is what is being read here; either
      -- way the oldest-first contract is what `_answer_pending_question` relies on.
      assert.equals("q-1", list[1].request_id)
    end)

    it("does not hand one chat another chat's question", function()
      open("q-1")
      open("q-2", { chat_bufnr = 2 })

      assert.equals(1, #PendingQuestions.list_for_chat(1))
      assert.equals("q-2", PendingQuestions.list_for_chat(2)[1].request_id)
    end)
  end)
end)

describe("the MCP route's own budget", function()
  local original

  before_each(function()
    original = require("vibing.config").get().permissions.approval_wait_sec
  end)

  after_each(function()
    require("vibing.config").get().permissions.approval_wait_sec = original
  end)

  it("waits exactly as long as an approval does", function()
    -- One configured number. A second knob would have to answer "why is a question worth a
    -- different wait than an approval?", and there is no answer.
    assert.equals(WaitBudget.approval_wait_sec(), WaitBudget.question_wait_sec())
  end)

  it("asks a backend to tolerate the wait plus the margin that carries the answer home", function()
    assert.equals(WaitBudget.question_wait_sec() + WaitBudget.MCP_MARGIN_SEC, WaitBudget.question_budget_sec())
  end)

  it("keeps the whole budget under the measured silence ceiling", function()
    -- A different phenomenon from `measured_answer_wait_sec` and kept separate on purpose, but it
    -- still bounds everything from above: past it the CLI aborts the call outright.
    assert.is_true(WaitBudget.question_budget_sec() < WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC)
  end)

  describe("which backends may answer in place", function()
    it("refuses a backend with no measurement at all", function()
      -- The safe default to forget: a new backend keeps killing the turn to ask until somebody runs
      -- `tests/perf/mcp_answer_after_delay.sh` against it.
      assert.is_false(WaitBudget.can_answer_question_in_place(nil))
      assert.is_false(WaitBudget.can_answer_question_in_place({}))
    end)

    it("accepts a measurement that covers the budget exactly", function()
      assert.is_true(
        WaitBudget.can_answer_question_in_place({ measured_answer_wait_sec = WaitBudget.question_budget_sec() })
      )
    end)

    it("refuses a measurement one second short of the budget", function()
      -- Not tidiness: the gap is where a human's answer is lost, because the CLI gave up while it
      -- was in flight.
      assert.is_false(
        WaitBudget.can_answer_question_in_place({ measured_answer_wait_sec = WaitBudget.question_budget_sec() - 1 })
      )
    end)

    it("turns itself off when the configured wait is raised past the evidence", function()
      -- The measurement decides, not a flag. Waiting longer means re-running the probe at the
      -- longer value, not raising the number and hoping.
      local measured = WaitBudget.question_budget_sec()
      require("vibing.config").get().permissions.approval_wait_sec = WaitBudget.approval_wait_sec() + 1

      assert.is_false(WaitBudget.can_answer_question_in_place({ measured_answer_wait_sec = measured }))
    end)
  end)
end)
