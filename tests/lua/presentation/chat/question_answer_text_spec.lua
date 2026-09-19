---@diagnostic disable: undefined-field
--- What travels back to the model as a question's answer.
---
--- The answer was whatever `extract_user_message` returned, which is the whole unsent section --
--- and the drawn block lives in that section. So the question text, its options and (since the
--- queue) the "N more waiting" line all went back to the model as the human's choice. Nothing
--- was misdelivered, but the model was handed its own question as the reply to it.
---
--- The drawn lines are removed the same way folding removes them: `renderer.strip_choice_lines`
--- rebuilds the block and matches it back out, so an untouched block goes and an edited one
--- stays. What is left over is the answer, and if nothing is left over there was no answer --
--- the same state an empty `<CR>` is in.
local ChatBuffers = require("tests.helpers.chat_buffers")
local PendingQuestions = require("vibing.infrastructure.rpc.pending_questions")
local PendingApprovals = require("vibing.infrastructure.rpc.pending_approvals")

describe("the text a question's answer is read from", function()
  local view
  local Q = { { question = "Which approach?", options = { { label = "A" }, { label = "B" } } } }

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

  --- A question registered, drawn into the buffer for real, holding a running turn open.
  ---
  --- Nothing here stubs `extract_user_message`: the defect is in what that function returns for
  --- a buffer with a block drawn in it, so a spec that replaces it cannot see the defect at all.
  --- @return Vibing.ChatBuffer, table replies
  local function question_drawn(request_id, questions)
    local chat_buf = view.render({ session_id = "answer-text" }, "back")
    local replies = {}
    PendingQuestions.open({
      request_id = request_id or "q-1",
      chat_bufnr = chat_buf.buf,
      questions = questions or Q,
      respond = function(result)
        table.insert(replies, result)
      end,
    })
    chat_buf._current_process_id = "proc-1"
    chat_buf._get_active_adapter = function()
      return {
        stop_turn = function() end,
      }
    end
    chat_buf:start_response()
    chat_buf:insert_choices(questions or Q, request_id or "q-1")
    chat_buf:show_pending_prompts()
    -- The state a question is always answered in: its own turn is still running.
    chat_buf._is_sending = true
    return chat_buf, replies
  end

  --- Type into the unsent section, where the cursor sits: under the drawn block.
  local function type_below_block(chat_buf, text)
    local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
    table.insert(lines, text)
    vim.api.nvim_buf_set_lines(chat_buf.buf, 0, -1, false, lines)
  end

  it("hands back what the user typed, not the question they were asked", function()
    local chat_buf, replies = question_drawn()
    type_below_block(chat_buf, "B, and keep the existing names")

    assert.is_true(chat_buf:send_message())

    assert.equals(1, #replies)
    assert.equals("B, and keep the existing names", replies[1].answer)
  end)

  it("does not hand back the count of the questions waiting behind it", function()
    -- The queue added a line to the block, so leaving the block in the answer now also tells the
    -- model how many other questions are pending -- which is bookkeeping, not a decision.
    local chat_buf, replies = question_drawn()
    PendingQuestions.open({
      request_id = "q-2",
      chat_bufnr = chat_buf.buf,
      questions = { { question = "Which file?", options = { { label = "X" } } } },
      respond = function() end,
    })
    chat_buf:insert_choices({ { question = "Which file?", options = { { label = "X" } } } }, "q-2")
    chat_buf:show_pending_prompts()
    type_below_block(chat_buf, "A")

    assert.is_true(chat_buf:send_message())

    assert.equals("A", replies[1].answer)
  end)

  it("is not an answer at all when the user typed nothing", function()
    -- An untouched block strips to nothing, and nothing is what an empty `<CR>` is. Spending the
    -- question here hands the model a blank where a decision should be -- and the block that was
    -- on screen reads exactly like one, which is why this is the case that used to pass.
    local chat_buf, replies = question_drawn()

    assert.is_false(chat_buf:send_message())

    assert.equals(0, #replies, "the drawn block was spent as the answer")
    assert.equals(1, #PendingQuestions.list_for_chat(chat_buf.buf), "the question is still answerable")
  end)

  it("does not hand back an approval prompt drawn in the same section", function()
    -- Both prompts are drawn into the one unsent section, and a `<CR>` reaches the question side
    -- only when the approval side did not claim it — which is exactly what typing prose rather
    -- than an option does. So the approval's own lines are in the text the answer is read from,
    -- and they are removed the way folding removes them, by the one function that knows them.
    local chat_buf, replies = question_drawn()
    chat_buf:insert_approval_request(
      "Bash",
      { command = "rm -rf build" },
      { { label = "allow_once", description = "Allow this execution only" } },
      "a-1",
      true
    )
    chat_buf:show_pending_prompts()
    type_below_block(chat_buf, "B, and leave build alone")

    chat_buf:send_message()

    assert.equals(1, #replies, "the question was not answered")
    assert.equals("B, and leave build alone", replies[1].answer)
  end)

  it("treats a block the user edited as the answer, whole", function()
    -- `strip_choice_lines` matches only what the renderer would have written, so one edited
    -- character leaves the block in place -- and `renderer.lua` already says that is correct:
    -- a block the user typed into is the answer. This pins that the fix did not quietly become
    -- "delete anything that looks like a question".
    local chat_buf, replies = question_drawn()
    local lines = vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)
    for index, line in ipairs(lines) do
      if line == "2. B" then
        lines[index] = "2. B  <- this one"
      end
    end
    vim.api.nvim_buf_set_lines(chat_buf.buf, 0, -1, false, lines)

    assert.is_true(chat_buf:send_message())

    assert.equals(1, #replies)
    assert.is_truthy(replies[1].answer:find("2. B  <- this one", 1, true), replies[1].answer)
  end)
end)
