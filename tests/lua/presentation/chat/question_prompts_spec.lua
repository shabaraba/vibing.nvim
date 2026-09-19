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
    --- The state expiry actually happens in: a running turn whose choices are drawn.
    ---
    --- **Drawing them for real is what makes these tests tests.** Written first as
    --- `chat_buf._prompts_rendered_unsent = true`, they set the flag the branch reads without ever
    --- creating the section the branch acts on — so `assert.is_false(..._rendered_unsent)` only
    --- read back a value the code assigns unconditionally, and the output the branch deletes was
    --- never there to be deleted. Same shape as the approval case #786 had to rewrite.
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
      -- The id travels with the choices exactly as the production path passes it, so "whose options
      -- are these" is answerable here rather than only in the module that sets it.
      chat_buf:insert_choices(
        { { question = "Which approach?", options = { { label = "A" } } } },
        request_id or "q-1"
      )
      chat_buf:start_response()
      chat_buf:show_pending_prompts()
      PendingQuestions.get(request_id or "q-1").on_timeout = function(entry)
        chat_buf:expire_question(entry)
      end
      return chat_buf, replies, stopped
    end

    local function body(chat_buf)
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    it("ends the turn when the question was the last prompt holding it", function()
      -- A refusal is a thing a model can act on; "nobody answered you" is not. Left running, the
      -- model has the choice it asked about still open and the obvious reading of the non-answer is
      -- to pick one — which is what asking existed to prevent.
      local chat_buf, replies, stopped = chat_whose_turn_can_be_watched()
      assert.is_true(chat_buf._prompts_rendered_unsent, "the branch under test was not reached")

      PendingQuestions.expire("q-1")

      assert.equals("unanswered", replies[1].status)
      assert.equals(1, #stopped, "the turn is stopped")
      assert.is_false(chat_buf._prompts_rendered_unsent, "the mid-turn unsent section is dropped")
      -- The explanation lands in the assistant's section, not in an open input field where the
      -- next `<CR>` would send it back to the model as the user's own words.
      local unsent = chat_buf:extract_user_message() or ""
      assert.is_nil(unsent:match("Question expired"), "the explanation is readable as a message:\n" .. unsent)
    end)

    it("keeps the output it was holding when it ends the turn", function()
      -- The hold has one promise: everything it swallows comes back out. Expiry used to flush while
      -- the unsent prompt section was still at the tail, so the flushed text landed *inside* that
      -- section and the drop that follows deleted it along with the options — and `_chunk_parts`
      -- was already empty, so it could not come back. Silent output loss, which is the one failure
      -- a user cannot even report.
      local chat_buf = chat_whose_turn_can_be_watched()
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            chat_buf:_finish_turn()
          end,
        }
      end
      chat_buf:append_chunk("a parallel tool's result\n")
      vim.wait(100)
      assert.is_nil(body(chat_buf):match("a parallel tool's result"), "precondition: still held")

      PendingQuestions.expire("q-1")
      vim.wait(100)

      assert.is_truthy(body(chat_buf):match("a parallel tool's result"), "held output was lost:\n" .. body(chat_buf))
    end)

    it("keeps what the user had started typing as their answer", function()
      -- The options are redrawn below the explanation, which is exactly the invitation to answer
      -- again — but only if the half-written answer survives to be finished. Dropping the section
      -- wholesale is the #786 failure, reached here through the question channel.
      local chat_buf = chat_whose_turn_can_be_watched()
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            chat_buf:_finish_turn()
          end,
        }
      end
      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(chat_buf.buf, #lines, #lines, false, { "A, but keep the old names" })

      PendingQuestions.expire("q-1")
      vim.wait(100)

      assert.is_truthy(body(chat_buf):match("A, but keep the old names"), body(chat_buf))
      -- And the options come back exactly once, not twice — the recycled copy and the redrawn one
      -- are the same prompt.
      local _, drawn = body(chat_buf):gsub("Which approach%?", "")
      assert.equals(1, drawn, "the options were drawn twice:\n" .. body(chat_buf))
    end)

    it("leaves the turn running while an approval is still blocked", function()
      -- claude dispatches several `tool_use` blocks from one assistant message at once, so a
      -- question and an approval hook are blocked in the same turn. Killing here would throw away
      -- the answer the user is in the middle of typing for the approval — the door next to the one
      -- #778 closed. The expiring question is the only thing that ends.
      local chat_buf, replies, stopped = chat_whose_turn_can_be_watched()
      PendingApprovals.open({
        request_id = "a-1",
        chat_bufnr = chat_buf.buf,
        tool = "Bash",
      })
      -- Drawn as well as registered, which is what production does — `on_approval_required` calls
      -- `insert_approval_request` before `show_pending_prompts`. The expiry folds the section and
      -- draws it again, so a registry-only approval would leave nothing to redraw and the
      -- assertion below would be pinning the absence of a prompt the user really does have.
      chat_buf:insert_approval_request("Bash", { command = "ls" }, {}, "a-1", true)

      PendingQuestions.expire("q-1")

      assert.equals("unanswered", replies[1].status, "the question itself is still answered")
      assert.equals(0, #stopped, "the turn the approval belongs to is not taken with it")
      assert.equals(1, PendingApprovals.count(), "the approval is still waiting for its human")
      assert.is_true(chat_buf._prompts_rendered_unsent, "the approval's own prompt stays on screen")
      assert.is_truthy(body(chat_buf):match("Tool: Bash"), "the approval was not redrawn:\n" .. body(chat_buf))
    end)

    it("does not empty the held output into the prompt still on screen", function()
      -- The other half of the same flush. With a prompt still blocked there is no drop to delete
      -- the text — it simply stays inside the open `## User`, where `extract_user_message` reads it
      -- as the user's own words. The remaining prompt is then answered with the assistant's prose.
      local chat_buf = chat_whose_turn_can_be_watched()
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = {},
        respond = function() end,
      })
      chat_buf:append_chunk("a parallel tool's result\n")
      vim.wait(100)

      PendingQuestions.expire("q-1")
      vim.wait(100)

      local unsent = chat_buf:extract_user_message() or ""
      assert.is_nil(unsent:match("a parallel tool's result"), "assistant prose became the answer:\n" .. unsent)
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

    it("takes the dead question's options off screen and does not put them back", function()
      -- Expiry folds the section and redraws it from the queue, and the expired question is no
      -- longer in the queue — so its options go, and the note that replaces them says nothing is
      -- waiting on it. What must not happen is the redraw putting them back: `add_user_section`
      -- draws the queue *before* it clears it, so an entry left behind reappears exactly once —
      -- long enough for the user to answer a question nobody is waiting on.
      local chat_buf = chat_whose_turn_can_be_watched()
      PendingApprovals.open({ request_id = "a-1", chat_bufnr = chat_buf.buf, tool = "Bash" })
      chat_buf:insert_approval_request("Bash", { command = "ls" }, {}, "a-1", true)

      PendingQuestions.expire("q-1")
      assert.equals(
        0,
        select(2, body(chat_buf):gsub("Which approach%?", "")),
        "the dead question's options are still on screen:\n" .. body(chat_buf)
      )

      -- What answering the approval that is still blocked does.
      chat_buf:add_user_section()

      assert.equals(
        0,
        select(2, body(chat_buf):gsub("Which approach%?", "")),
        "the expired question's options came back:\n" .. body(chat_buf)
      )
    end)

    it("keeps the options of the question that is still waiting", function()
      -- Why the drop is keyed on the id rather than done unconditionally. `_pending_choices` is a
      -- single field, so the second of two questions overwrites the first's block — and an
      -- unconditional drop on the first one's expiry would take the **live** one's options with it,
      -- leaving "answer this" with nothing to answer. The usual case (`others` is an approval) has
      -- the ids agreeing, so it still drops.
      local chat_buf = chat_whose_turn_can_be_watched()
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = { { question = "Which file?", options = { { label = "X" } } } },
        respond = function() end,
      })
      chat_buf:insert_choices({ { question = "Which file?", options = { { label = "X" } } } }, "q-2")

      PendingQuestions.expire("q-1")
      chat_buf:add_user_section()

      assert.equals("q-2", chat_buf._pending_choices_request_id, "the live question lost its block")
      assert.is_truthy(body(chat_buf):match("Which file%?"), "the live question lost its options:\n" .. body(chat_buf))
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

    it("does not hand an expired approval's option line to the waiting question", function()
      -- **The outcome the case above does not reach.** `answered_in_place` returns at the guard
      -- above the question call; `retry_as_new_turn` falls through it, and that is the one the user
      -- actually produces — answering an approval whose hook already expired. The approval is spent
      -- by then, so what arrives at the question side is
      -- `1. allow_once - Allow this execution only <!-- vibing:req=... -->` and the model reads it
      -- as the human's answer to "which approach?". Worse, `send_message` returns true, so the
      -- retry message the spent approval built is never sent either.
      local chat_buf, replies = chat_awaiting_question()
      chat_buf._is_sending = true
      chat_buf._answer_pending_approval = function()
        return { outcome = "retry_as_new_turn", message = "Retry the Bash call; it is allowed now." }
      end
      chat_buf.extract_user_message = function()
        return "1. allow_once - Allow this execution only <!-- vibing:req=a-expired -->"
      end

      chat_buf:send_message()

      assert.equals(0, #replies, "the option line was delivered as the question's answer")
      assert.equals(1, PendingQuestions.count(), "the question is still waiting for a real answer")
    end)
  end)

  describe("the options of a question that is still waiting", function()
    it("survive the redraw that answering an approval triggers", function()
      -- `add_user_section` drops `_pending_choices` once it has drawn them, which is right on the
      -- kill path where the drawing happens once. On the waiting path it is drawn again every time
      -- a prompt is answered or another arrives, and the first redraw would leave the still-blocked
      -- question with an empty input box: "answer this" with nothing to answer.
      local chat_buf = chat_awaiting_question()
      chat_buf:insert_choices({ { question = "Which approach?", options = { { label = "A" } } } })
      chat_buf:start_response()
      chat_buf:show_pending_prompts()

      -- What answering the last approval does while a question is still blocked.
      chat_buf:add_user_section()

      local body = table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
      assert.is_truthy(body:match("Which approach%?"), "the waiting question lost its options:\n" .. body)
      assert.is_not_nil(chat_buf._pending_choices, "they must still be redrawable while it waits")
    end)

    it("are dropped once nothing is waiting on them", function()
      -- The other side of the same condition: keep them past the wait and every later turn's input
      -- box carries a question that was answered long ago.
      local chat_buf = chat_awaiting_question()
      chat_buf:insert_choices({ { question = "Which approach?", options = { { label = "A" } } } })
      PendingQuestions._reset()

      chat_buf:add_user_section()

      assert.is_nil(chat_buf._pending_choices)
    end)
  end)

  describe("which question an answer belongs to", function()
    --- The failure #795 introduces rather than inherits. The **overwrite** — a second question
    --- replacing the first's block, so only the second is ever on screen — is in `origin/main` too,
    --- and there the answer arrives as the prose of a **new turn**, which a model can read and
    --- recover from. Here it is delivered as the **result of a tool call**, so taking the oldest
    --- waiting question silently makes the user's answer to Q2 into Q1's answer, and Q2 then waits
    --- out its whole limit. One level below "an answer belongs to the chat that was asked" (#667).
    ---
    --- @return Vibing.ChatBuffer, table q1_replies, table q2_replies
    local function two_questions_waiting()
      local chat_buf, first = chat_awaiting_question("q-1")
      local second = {}
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = { { question = "Which file?", options = { { label = "X" } } } },
        respond = function(result)
          table.insert(second, result)
        end,
      })
      -- What the user is actually looking at: the second question's block, because staging it
      -- replaced the first's.
      chat_buf:insert_choices({ { question = "Which file?", options = { { label = "X" } } } }, "q-2")
      chat_buf._is_sending = true
      chat_buf.extract_user_message = function()
        return "X"
      end
      return chat_buf, first, second
    end

    it("answers the one whose options are on screen, not the oldest", function()
      local chat_buf, first, second = two_questions_waiting()

      assert.is_true(chat_buf:send_message())

      assert.equals(0, #first, "the answer went to a question the user never saw")
      assert.equals("answered", second[1].status)
      assert.equals("X", second[1].answer)
    end)

    it("refuses to guess when nothing says which block is on screen", function()
      -- The approval side's shape: ambiguous means refuse and spend nothing, never fall back to a
      -- default that is wrong half the time. Both questions stay answerable.
      local chat_buf, first, second = two_questions_waiting()
      chat_buf:_clear_pending_choices()

      local warned = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        table.insert(warned, msg)
      end
      local ok = chat_buf:send_message()
      vim.notify = original_notify

      assert.is_false(ok)
      assert.equals(0, #first)
      assert.equals(0, #second)
      assert.equals(2, PendingQuestions.count(), "an answer was spent on a guess")
      assert.equals(1, #warned, "the refusal was silent, which is the failure it replaces")
    end)

    it("still answers the sole waiting question when nothing marks the options", function()
      -- The control, and the kill path's shape: choices staged with no id because no question was
      -- registered to own them. With one waiting there is nothing to confuse it with, so refusing
      -- here would turn the fix into "questions can no longer be answered at all".
      local chat_buf, replies = chat_awaiting_question("q-1")
      chat_buf:insert_choices({ { question = "Which approach?", options = { { label = "A" } } } })
      chat_buf._is_sending = true
      chat_buf.extract_user_message = function()
        return "A"
      end

      assert.is_true(chat_buf:send_message())
      assert.equals("answered", replies[1].status)
      assert.equals("A", replies[1].answer)
    end)
  end)

  describe("a second question arriving while the first is on screen", function()
    --- `_pending_choices` held one question, so the second `nvim_ask_user_question` of a single
    --- assistant message replaced the first's block. What that costs is not only that the first
    --- goes unseen: `_recycle_prompt_section` strips the drawn block by **rebuilding it** from
    --- `_pending_choices`, so once the field holds the second question the first's drawn lines
    --- match nothing, survive the fold, and come back as the user's own unsent text.
    ---
    --- Both are held now, oldest first, and only the head is drawn — a free-text answer carries
    --- nothing that says which of two drawn blocks it belongs to, which is why the queue is not
    --- also a second block on screen.
    local Q1 = { { question = "Which approach?", options = { { label = "A" } } } }
    local Q2 = { { question = "Which file?", options = { { label = "X" } } } }

    local function body(chat_buf)
      return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
    end

    --- One question registered, drawn, and holding the turn open.
    --- @return Vibing.ChatBuffer, table replies, table stopped
    local function first_question_on_screen()
      local chat_buf, replies = chat_awaiting_question("q-1")
      local stopped = {}
      chat_buf._current_process_id = "proc-1"
      chat_buf._get_active_adapter = function()
        return {
          stop_turn = function()
            table.insert(stopped, true)
          end,
        }
      end
      chat_buf:start_response()
      chat_buf:insert_choices(Q1, "q-1")
      chat_buf:show_pending_prompts()
      return chat_buf, replies, stopped
    end

    --- ...and a second one arriving the way the CLI delivers it: staged, then drawn.
    --- @return Vibing.ChatBuffer, table q1_replies, table q2_replies, table stopped
    local function both_waiting()
      local chat_buf, first, stopped = first_question_on_screen()
      local second = {}
      PendingQuestions.open({
        request_id = "q-2",
        chat_bufnr = chat_buf.buf,
        questions = Q2,
        respond = function(result)
          table.insert(second, result)
        end,
      })
      PendingQuestions.get("q-2").on_timeout = function(entry)
        chat_buf:expire_question(entry)
      end
      chat_buf:insert_choices(Q2, "q-2")
      chat_buf:show_pending_prompts()
      return chat_buf, first, second, stopped
    end

    it("does not turn the first question's block into the user's own message", function()
      -- The failure the queue exists to close. Everything below it is only reachable once this
      -- holds: while the first question's lines are sitting in the input field, the next `<CR>`
      -- hands the model its own question back as the human's answer.
      local chat_buf = both_waiting()

      local unsent = chat_buf:extract_user_message() or ""
      assert.equals(
        1,
        select(2, unsent:gsub("Which approach%?", "")),
        "the first question's block was carried into the user's text:\n" .. unsent
      )
    end)

    it("draws only the oldest, and says how many more are waiting", function()
      -- FIFO, and one block at a time. Two blocks on screen would leave a free-text answer with
      -- two possible owners and no way to tell them apart — the line the count replaces.
      local chat_buf = both_waiting()
      local text = body(chat_buf)

      assert.equals(1, select(2, text:gsub("Which approach%?", "")), "the oldest question is not the one on screen")
      assert.equals(0, select(2, text:gsub("Which file%?", "")), "the queued question was drawn as a second block")
      assert.is_truthy(text:match("1 more question is waiting"), "the queued one is invisible with nothing said:\n" .. text)
    end)

    it("answers the one on screen and then draws the next", function()
      local chat_buf, first, second = both_waiting()
      chat_buf._is_sending = true
      chat_buf.extract_user_message = function()
        return "A"
      end

      assert.is_true(chat_buf:send_message())

      assert.equals("answered", first[1].status)
      assert.equals("A", first[1].answer)
      assert.equals(0, #second, "the answer was spent on the question the user could not see")
      assert.equals("q-2", chat_buf._pending_choices_request_id, "the next question was not promoted")
      assert.is_truthy(body(chat_buf):match("Which file%?"), "the next question was never drawn:\n" .. body(chat_buf))
    end)

    it("does not leak the drawn block when the queue count changes under it", function()
      -- The count line makes the drawn block a function of the **whole** queue, so a question
      -- leaving the queue changes what `strip_choice_lines` rebuilds. Dropping it before folding
      -- leaves the drawn block matching nothing, and it is carried into the user's own text —
      -- the same failure as the one above, re-entered through the line that mitigates it.
      local chat_buf = both_waiting()

      PendingQuestions.expire("q-2")

      local unsent = chat_buf:extract_user_message() or ""
      assert.equals(
        1,
        select(2, unsent:gsub("Which approach%?", "")),
        "the drawn block was duplicated or carried as user text:\n" .. unsent
      )
      assert.is_nil(unsent:match("more question"), "the count line still claims a question is waiting:\n" .. unsent)
      assert.is_nil(unsent:match("Question expired"), "the explanation is readable as the user's message:\n" .. unsent)
    end)

    it("explains a question that expired without ever being drawn", function()
      -- The queued one is invisible for its whole wait, so its expiry note is the only thing that
      -- ever tells the user it existed. Dropping it from the queue in silence explains nothing.
      local chat_buf, _, second, stopped = both_waiting()

      PendingQuestions.expire("q-2")

      assert.equals("unanswered", second[1].status)
      assert.is_truthy(body(chat_buf):match("Question expired"), body(chat_buf))
      assert.equals(0, #stopped, "the turn the drawn question still holds was ended with it")
      assert.equals(1, PendingQuestions.count(), "the drawn question was taken with it")
    end)

    it("holds nothing once the turn that asked is cancelled", function()
      -- Releasing every blocked prompt means nothing is waiting on this chat any more, so a queue
      -- left behind makes the next redraw print a count line for questions that were answered as
      -- unanswered several seconds ago.
      local chat_buf = both_waiting()

      chat_buf:cancel_request()

      assert.is_nil(chat_buf._pending_choices, "the cancelled turn's questions are still queued")
    end)

    it("does not leak the drawn block when the CLI dies before the questions are answered", function()
      -- The third mouth onto the queue, and the one the first version of this change got wrong.
      -- `_release_blocked_prompts` emptied the queue and `_finish_turn` folded six lines later,
      -- so `strip_choice_lines` rebuilt from an empty queue, returned early without removing a
      -- single line, and the drawn block became the user's own unsent text — the failure this
      -- whole change exists to close, arriving through the path where the CLI died first.
      --
      -- The observation point is the drawn block, not the count line: emptying the queue makes
      -- the count line correct and the fold wrong, so a spec watching the count passes.
      local chat_buf = both_waiting()

      chat_buf:_finish_turn()

      local unsent = chat_buf:extract_user_message() or ""
      assert.is_nil(unsent:match("Which approach%?"), "the drawn block became the user's message:\n" .. unsent)
      assert.is_nil(
        (chat_buf._pending_user_text or ""):match("Which approach%?"),
        "it is still queued to be redrawn as user text: " .. tostring(chat_buf._pending_user_text)
      )
    end)

    it("leaves exactly one input box behind when a cancel releases the questions", function()
      -- Folding is only half of the discipline, and it can go wrong in both directions. A fold
      -- with no redraw after it takes the input field off screen and leaves the chat with nowhere
      -- to type; a redraw inside the release as well as in `_finish_turn` leaves two unsent
      -- sections, and only one of them is the one `extract_user_message` reads.
      local chat_buf = both_waiting()

      chat_buf:cancel_request()
      chat_buf:_finish_turn()

      -- Counted below the last assistant header, not over the whole buffer: a chat opens with an
      -- unsent `## User` of its own, and that one is not what this turn drew.
      local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
      local Timestamp = require("vibing.core.utils.timestamp")
      local last_assistant = 0
      for index, line in ipairs(lines) do
        local header = Timestamp.parse_header(line)
        if header and header.kind == "Assistant" then
          last_assistant = index
        end
      end

      local boxes = 0
      for index = last_assistant + 1, #lines do
        local header = Timestamp.parse_header(lines[index])
        if header and header.unsent then
          boxes = boxes + 1
        end
      end
      assert.equals(1, boxes, "wrong number of places to type:\n" .. table.concat(lines, "\n"))
    end)

    it("replaces a block rather than queueing a duplicate when the same id is staged again", function()
      -- The approval list's shape: a hook cut and re-run arrives carrying the id it already had.
      -- Appending would draw one question twice over and count a phantom second one as waiting.
      local chat_buf = first_question_on_screen()

      chat_buf:insert_choices({ { question = "Which approach, really?", options = { { label = "A" } } } }, "q-1")
      chat_buf:show_pending_prompts()

      assert.equals(1, #chat_buf._pending_choices)
      assert.is_nil(body(chat_buf):match("1 more question is waiting"), body(chat_buf))
    end)
  end)
end)
