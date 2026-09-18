---@diagnostic disable: undefined-field
--- A question that holds its turn open, from the chat buffer's side (#788).
---
--- What changes for the chat once `nvim_ask_user_question` stops killing the turn is the same set
--- of things #778 changed for approvals, and these specs pin the three that are easy to break from
--- the code: the status a waiting chat reports, the order in which a cancelled turn lets go of what
--- it is holding, and what a `<CR>` means while a question is waiting.
local ChatBuffers = require("tests.helpers.chat_buffers")
local PendingQuestions = require("vibing.infrastructure.rpc.pending_questions")
local PendingApprovals = require("vibing.infrastructure.rpc.pending_approvals")

describe("a question holding the turn open", function()
  local view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
    PendingQuestions._reset()
    PendingApprovals._reset()
  end)

  after_each(function()
    PendingQuestions._reset()
    PendingApprovals._reset()
    ChatBuffers.reset()
  end)

  --- @return Vibing.ChatBuffer, table replies
  local function chat_awaiting_question(request_id)
    local chat_buf = view.render({ session_id = "questions" }, "back")
    local replies = {}
    PendingQuestions.open({
      request_id = request_id or "q-1",
      chat_bufnr = chat_buf.buf,
      questions = { { question = "Which approach?", options = { { label = "A" }, { label = "B" } } } },
      respond = function(result)
        table.insert(replies, result)
      end,
    })
    return chat_buf, replies
  end

  describe("what the chat reports while it waits", function()
    it("says asked_question even though its turn is still running", function()
      -- The hole #778 closed for approvals, re-opened from the other end. Without this, a chat
      -- waiting for a human reports `responding` for the whole wait, and an orchestrator polling it
      -- sees a worker that is still busy rather than one that needs an answer.
      local chat_buf = chat_awaiting_question()
      local ChatStatus = require("vibing.presentation.chat.modules.chat_status")

      -- Make the chat genuinely look like it is responding, which is the case that matters.
      chat_buf.is_responding = function()
        return true
      end

      assert.equals("asked_question", ChatStatus.get(chat_buf.buf))
    end)

    it("goes back to responding once the question is answered", function()
      local chat_buf = chat_awaiting_question()
      local ChatStatus = require("vibing.presentation.chat.modules.chat_status")
      chat_buf.is_responding = function()
        return true
      end

      PendingQuestions.resolve("q-1", { status = "answered", answer = "A" })
      assert.equals("responding", ChatStatus.get(chat_buf.buf))
    end)

    it("does not report another chat's waiting question", function()
      local chat_buf = chat_awaiting_question()
      local other = view.render({ session_id = "other" }, "back")
      local ChatStatus = require("vibing.presentation.chat.modules.chat_status")
      chat_buf.is_responding = function()
        return true
      end

      assert.is_not.equals("asked_question", ChatStatus.get(other.buf))
    end)
  end)

  describe("letting go before the CLI is killed", function()
    it("replies to the waiting question before it stops the turn", function()
      -- A killed CLI can no longer be the thing that stops waiting, so the reply has to be written
      -- while the process is still alive. Same ordering as the approval registry owes, and the same
      -- consequence if it is lost: a CLI blocked inside a tool call until its own idle timeout.
      local chat_buf, replies = chat_awaiting_question()
      local order = {}

      chat_buf._current_process_id = "proc-1"
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            table.insert(order, "turn stopped")
          end,
        }
      end
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = {},
        respond = function(result)
          table.insert(order, "replied")
          table.insert(replies, result)
        end,
      })

      chat_buf:cancel_request()

      assert.equals("replied", order[1])
      assert.equals("turn stopped", order[#order])
      assert.equals(0, PendingQuestions.count())
    end)

    it("answers a question the turn outlived, rather than leaving it to the limit", function()
      -- The CLI died first. Nobody can answer this one now, and waiting for the limit would explain
      -- it 15 minutes later with a reason that is not what happened.
      local chat_buf, replies = chat_awaiting_question()

      chat_buf:_finish_turn()

      assert.equals(1, #replies)
      assert.equals("unanswered", replies[1].status)
      assert.is_truthy(replies[1].reason:find("ended before", 1, true))
    end)
  end)

  describe("what <CR> means while a question waits", function()
    it("hands the user's text back to the waiting call instead of sending a new turn", function()
      local chat_buf, replies = chat_awaiting_question()
      chat_buf.extract_user_message = function()
        return "B, and keep the existing names"
      end

      assert.is_true(chat_buf:send_message())

      assert.equals(1, #replies)
      assert.equals("answered", replies[1].status)
      assert.equals("B, and keep the existing names", replies[1].answer)
    end)

    it("never spends an empty message as the answer", function()
      -- Pressing <CR> on an empty input is not an answer, and handing the model a blank where a
      -- decision should be is the one outcome that must not happen.
      --
      -- It is not a no-op either, and that is worth stating rather than discovering: the press
      -- falls through to the ordinary send path, whose `cancel_request()` ends the turn and
      -- releases this question as **unanswered**. That is the same thing #778 already does when a
      -- user types a new message instead of answering a blocked approval — `cancel_request` runs
      -- before `send_message` ever looks at whether there is a message — so the behaviour is
      -- shared rather than new. What this pins is only that the reply says `unanswered`.
      local chat_buf, replies = chat_awaiting_question()
      chat_buf.extract_user_message = function()
        return ""
      end

      chat_buf:send_message()

      assert.equals(1, #replies)
      assert.equals("unanswered", replies[1].status)
    end)

    it("answers while the turn is still streaming, which is the only state a question is asked in", function()
      -- **The state every other case here forgets to be in.** `_is_sending` is set by
      -- `send_message` and cleared only by `_handle_response`, so it is true for the whole of a
      -- running turn — and a question can only be asked by a turn that is running. Left in the
      -- duplicate-send guard's way the answer reaches nothing at all: the reply is never written,
      -- and the CLI sits inside the tool call until its own MCP idle timeout.
      local chat_buf, replies = chat_awaiting_question()
      chat_buf._is_sending = true
      chat_buf.extract_user_message = function()
        return "A"
      end

      assert.is_true(chat_buf:send_message())
      assert.equals(1, #replies)
      assert.equals("answered", replies[1].status)
      assert.equals("A", replies[1].answer)
    end)

    it("does not start a new turn when a streaming chat's <CR> was not an answer", function()
      -- The guard is opened for an answer and closed again straight after. An empty `<CR>` while
      -- the turn is genuinely running is a **no-op**: the question stays waiting and the limit is
      -- what eventually ends it. Letting it fall through instead would cancel the running turn on a
      -- stray keypress, which is precisely the duplicate send the guard exists to stop.
      local chat_buf, replies = chat_awaiting_question()
      chat_buf._is_sending = true
      chat_buf.extract_user_message = function()
        return ""
      end

      assert.is_false(chat_buf:send_message())
      assert.equals(0, #replies, "nothing was spent; the question is still answerable")
      assert.equals(1, #PendingQuestions.list_for_chat(chat_buf.buf))
    end)

    it("drops the choices once answered, so a later turn does not redraw them", function()
      local chat_buf = chat_awaiting_question()
      chat_buf:insert_choices({ { question = "Which approach?" } })
      chat_buf.extract_user_message = function()
        return "A"
      end

      chat_buf:send_message()
      assert.is_nil(chat_buf._pending_choices)
    end)

    it("falls back to an ordinary send once the question has expired", function()
      -- The expiry route is today's route: the registry entry is gone, so nothing here claims the
      -- message and it travels as a new turn exactly as it does now.
      local chat_buf, replies = chat_awaiting_question()
      PendingQuestions.expire("q-1")
      assert.equals("unanswered", replies[1].status)

      chat_buf.extract_user_message = function()
        return "A"
      end

      assert.is_nil(chat_buf:_answer_pending_question())
    end)
  end)

  describe("what expiry does to the turn", function()
    --- @return Vibing.ChatBuffer, table replies, table stopped
    local function chat_whose_turn_can_be_watched(request_id)
      local chat_buf, replies = chat_awaiting_question(request_id)
      local stopped = {}
      chat_buf._current_process_id = "proc-1"
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            table.insert(stopped, true)
          end,
        }
      end
      PendingQuestions.get(request_id or "q-1").on_timeout = function(entry)
        chat_buf:expire_question(entry)
      end
      return chat_buf, replies, stopped
    end

    it("ends the turn when the question was the last prompt holding it", function()
      -- A refusal is a thing a model can act on; "nobody answered you" is not. Left running, the
      -- model has the choice it asked about still open and the obvious reading of the non-answer is
      -- to pick one — which is what asking existed to prevent.
      local chat_buf, replies, stopped = chat_whose_turn_can_be_watched()
      -- The options were drawn mid-turn, so there is an unsent section to drop. Left in place it
      -- would sit below the explanation and `extract_user_message` would read it.
      chat_buf._prompts_rendered_unsent = true

      PendingQuestions.expire("q-1")

      assert.equals("unanswered", replies[1].status)
      assert.equals(1, #stopped, "the turn is stopped")
      assert.is_false(chat_buf._prompts_rendered_unsent, "the mid-turn unsent section is dropped")
    end)

    it("leaves the turn running while an approval is still blocked", function()
      -- claude dispatches several `tool_use` blocks from one assistant message at once, so a
      -- question and an approval hook are blocked in the same turn. Killing here would throw away
      -- the answer the user is in the middle of typing for the approval — the door next to the one
      -- #778 closed. The expiring question is the only thing that ends.
      local chat_buf, replies, stopped = chat_whose_turn_can_be_watched()
      chat_buf._prompts_rendered_unsent = true
      PendingApprovals.open({
        request_id = "a-1",
        chat_bufnr = chat_buf.buf,
        tool = "Bash",
      })

      PendingQuestions.expire("q-1")

      assert.equals("unanswered", replies[1].status, "the question itself is still answered")
      assert.equals(0, #stopped, "the turn the approval belongs to is not taken with it")
      assert.equals(1, PendingApprovals.count(), "the approval is still waiting for its human")
      assert.is_true(chat_buf._prompts_rendered_unsent, "the approval's own prompt stays on screen")
    end)

    it("leaves the turn running while a second question is still blocked", function()
      -- The condition is about prompts, not about which registry they live in. One assistant
      -- message can carry two `nvim_ask_user_question` calls.
      local chat_buf, replies, stopped = chat_whose_turn_can_be_watched()
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = {},
        respond = function() end,
      })

      PendingQuestions.expire("q-1")

      assert.equals("unanswered", replies[1].status)
      assert.equals(0, #stopped)
      assert.equals(1, PendingQuestions.count())
    end)
  end)

  describe("output that arrives while a question is waiting", function()
    --- The same append-only problem #778 solved for approvals, on the channel that arrived after
    --- it. A waiting question's choices are drawn by `show_pending_prompts` — the *shared* entry
    --- point — as an unsent `## User` section at the end of the buffer, and `_flush_chunks` appends
    --- at the end too. So anything flushed while a question waits lands under the input field,
    --- where `extract_user_message` reads it back as the user's next message.
    ---
    --- The hold was keyed on `pending_approvals` alone, which is exactly the drift
    --- `.claude/rules/permissions.md` names: the drawing was merged and the condition was not.
    local function text(chat_buf)
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    local function line_index(chat_buf, needle)
      for index, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
        if line:find(needle, 1, true) then
          return index
        end
      end
      return nil
    end

    --- The state a question is actually asked in: a running turn that has drawn its choices.
    local function chat_streaming_under_a_question()
      local chat_buf, replies = chat_awaiting_question()
      chat_buf:insert_choices({ { question = "Which approach?", options = { { label = "A" } } } })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      return chat_buf, replies
    end

    it("streams normally when no question is waiting", function()
      -- The control. Without it "the text never appeared" is green whether the hold worked or the
      -- harness simply never flushes anything.
      local chat_buf = view.render({ session_id = "questions" }, "back")
      chat_buf:start_response()
      chat_buf:append_chunk("ordinary output\n")

      vim.wait(300, function()
        return line_index(chat_buf, "ordinary output") ~= nil
      end)
      assert.is_not_nil(line_index(chat_buf, "ordinary output"), text(chat_buf))
    end)

    it("holds it while the question waits", function()
      local chat_buf = chat_streaming_under_a_question()
      chat_buf:append_chunk("a parallel tool's result\n")

      vim.wait(300)
      assert.is_nil(line_index(chat_buf, "a parallel tool's result"), text(chat_buf))
    end)

    it("does not hold for choices drawn after the question stopped waiting", function()
      -- The hold is keyed on the registry, not on the lines. The kill path leaves its choices drawn
      -- after the turn dies and nothing is blocked on them, so keying on `_pending_choices` would
      -- mean every later turn rendered nothing at all.
      local chat_buf = chat_streaming_under_a_question()
      PendingQuestions._reset()
      chat_buf:append_chunk("the next turn's output\n")

      vim.wait(300, function()
        return line_index(chat_buf, "the next turn's output") ~= nil
      end)
      assert.is_not_nil(line_index(chat_buf, "the next turn's output"), text(chat_buf))
    end)

    it("flushes what it held once the question is answered", function()
      -- The hold is only safe because every exit drains it. The question side's exit is
      -- `_answer_pending_question`, which reaches `_flush_chunks` through `_resume_after_prompts`.
      local chat_buf, replies = chat_streaming_under_a_question()
      chat_buf:append_chunk("arrived while waiting\n")
      chat_buf.extract_user_message = function()
        return "A"
      end

      assert.is_true(chat_buf:send_message())
      assert.equals("answered", replies[1].status)

      local held = line_index(chat_buf, "arrived while waiting")
      assert.is_not_nil(held, "the held output must reappear:\n" .. text(chat_buf))

      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      for index = held, #lines do
        assert.is_nil(
          lines[index]:match("^## User"),
          "no input section may sit above the flushed output:\n" .. text(chat_buf)
        )
      end
    end)
  end)

  describe("a question and an approval waiting at once", function()
    it("does not let an approval answer be swallowed as a question answer", function()
      -- Both prompts are answered through `send_message`, and only the approval side can tell
      -- whether a message was addressed to it. Asking the question side first would consume an
      -- `allow_once` as the text of an answer, leaving the hook blocked.
      local chat_buf, replies = chat_awaiting_question()
      local answered_approval = false
      chat_buf._answer_pending_approval = function()
        answered_approval = true
        return { outcome = "answered_in_place" }
      end
      chat_buf.extract_user_message = function()
        return "allow_once"
      end

      assert.is_true(chat_buf:send_message())
      assert.is_true(answered_approval)
      assert.equals(0, #replies)
      assert.equals(1, PendingQuestions.count())
    end)
  end)
end)
