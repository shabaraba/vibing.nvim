---@diagnostic disable: undefined-field
--- The chat side of the queued prompt tools: entries the model queued during a turn become a choice
--- list and a confirmation block in the next unsent section, without reading the reply's text.
local ChatBuffers = require("tests.helpers.chat_buffers")
local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")

describe("ChatBuffer:render_queued_prompts", function()
  local view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
  end)

  after_each(function()
    ChatBuffers.reset()
  end)

  ---@return Vibing.ChatBuffer
  local function chat()
    local chat_buf = view.render({ session_id = "queued-prompts" }, "back")
    chat_buf:start_response()
    chat_buf:append_chunk("Done.\n")
    chat_buf:_flush_chunks()
    return chat_buf
  end

  ---@param chat_buf Vibing.ChatBuffer
  ---@return string
  local function text(chat_buf)
    return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
  end

  ---@param label string
  ---@return table
  local function question(label)
    return { question = label, options = { { label = "A" }, { label = "B" } } }
  end

  it("draws a queued question as a choice list and reports asked_question", function()
    local chat_buf = chat()

    assert.is_true(chat_buf:render_queued_prompts({
      { kind = "question", questions = { question("Which one?") } },
    }))
    assert.equals("asked_question", chat_buf:get_stop_reason())

    chat_buf:add_user_section()
    local buffer = text(chat_buf)
    assert.is_truthy(buffer:find("Which one?", 1, true), buffer)
    assert.is_truthy(buffer:find("1. A", 1, true), buffer)
    assert.is_truthy(buffer:find("2. B", 1, true), buffer)
  end)

  it("merges questions from several calls into one drawn block", function()
    local chat_buf = chat()

    chat_buf:render_queued_prompts({
      { kind = "question", questions = { question("First?") } },
      { kind = "question", questions = { question("Second?") } },
    })
    chat_buf:add_user_section()

    local buffer = text(chat_buf)
    assert.is_truthy(buffer:find("First?", 1, true), buffer)
    assert.is_truthy(buffer:find("Second?", 1, true), buffer)
    -- One block only: the second call replaced nothing and does not add a "(1 more question)" line.
    assert.is_nil(buffer:find("more question", 1, true), buffer)
  end)

  it("draws a confirmation block and reports asked_question", function()
    local chat_buf = chat()

    assert.is_true(chat_buf:render_queued_prompts({
      {
        kind = "approval",
        reason = "I am about to delete build/.",
        tool = "Bash",
        input = { command = "rm -rf build", details = { "in the repository root" } },
      },
    }))
    -- Not `waiting_approval`: the confirmation is not in the approval registry, so the answer is a
    -- message rather than `nvim_chat_answer_approval`.
    assert.equals("asked_question", chat_buf:get_stop_reason())

    chat_buf:add_user_section()
    local buffer = text(chat_buf)
    assert.is_truthy(buffer:find(ApprovalParser.CONFIRMATION_HEADER, 1, true), buffer)
    assert.is_truthy(buffer:find("I am about to delete build/.", 1, true), buffer)
    assert.is_truthy(buffer:find("Command: rm -rf build", 1, true), buffer)
    assert.is_truthy(buffer:find("in the repository root", 1, true), buffer)
    -- Advisory options, not permission actions: the line the user keeps is the answer.
    assert.is_truthy(buffer:find("1. Proceed", 1, true), buffer)
    assert.is_truthy(buffer:find("2. Do not proceed", 1, true), buffer)
    assert.is_truthy(buffer:find(ApprovalParser.CONFIRMATION_INSTRUCTION, 1, true), buffer)
  end)

  it("omits the options when more than one confirmation would make them ambiguous", function()
    local chat_buf = chat()

    chat_buf:render_queued_prompts({
      { kind = "approval", reason = "Delete build/?" },
      { kind = "approval", reason = "Delete dist/?" },
    })
    chat_buf:add_user_section()

    local buffer = text(chat_buf)
    assert.is_truthy(buffer:find("Delete build/?", 1, true), buffer)
    assert.is_truthy(buffer:find("Delete dist/?", 1, true), buffer)
    assert.is_nil(buffer:find("1. Proceed", 1, true), buffer)
  end)

  ---@param chat_buf Vibing.ChatBuffer
  ---@param text string
  ---@return boolean
  local function delete_line(chat_buf, text)
    for index, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false)) do
      if line == text then
        vim.api.nvim_buf_set_lines(chat_buf.buf, index - 1, index, false, {})
        return true
      end
    end
    return false
  end

  it("sends only the kept option, not the block's scaffolding", function()
    local chat_buf = chat()
    chat_buf:render_queued_prompts({ { kind = "approval", reason = "Delete build/?" } })
    chat_buf:add_user_section()

    assert.is_true(delete_line(chat_buf, "2. Do not proceed"))

    -- The header, the reason and the human-directed instruction are UI, not the answer.
    assert.equals("1. Proceed", chat_buf:extract_user_message())
  end)

  it("keeps what the user typed under the confirmation", function()
    local chat_buf = chat()
    chat_buf:render_queued_prompts({ { kind = "approval", reason = "Delete build/?" } })
    chat_buf:add_user_section()

    assert.is_true(delete_line(chat_buf, "2. Do not proceed"))
    local count = vim.api.nvim_buf_line_count(chat_buf.buf)
    vim.api.nvim_buf_set_lines(chat_buf.buf, count, count, false, { "Ship it." })

    assert.equals("1. Proceed\n\nShip it.", chat_buf:extract_user_message())
  end)

  it("strips an unanswered confirmation out of the user's next message", function()
    local chat_buf = chat()
    chat_buf:render_queued_prompts({ { kind = "approval", reason = "Delete build/?" } })
    chat_buf:add_user_section()

    local kept = ApprovalParser.strip_prompt_lines(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false))
    local remaining = table.concat(kept, "\n")

    assert.is_nil(remaining:find(ApprovalParser.CONFIRMATION_HEADER, 1, true))
    assert.is_nil(remaining:find("Delete build/?", 1, true))
    -- The option lines are the answer, so stripping the block must leave them alone.
    assert.is_truthy(remaining:find("1. Proceed", 1, true), remaining)
  end)

  it("does not redraw what it already drew", function()
    local chat_buf = chat()
    chat_buf:render_queued_prompts({ { kind = "question", questions = { question("Once?") } } })
    chat_buf:add_user_section()
    chat_buf:add_user_section()

    local buffer = text(chat_buf)
    local _, count = buffer:gsub("Once%?", "")
    assert.equals(1, count)
  end)

  it("does nothing for an empty queue", function()
    local chat_buf = chat()

    assert.is_false(chat_buf:render_queued_prompts({}))
    assert.is_nil(chat_buf:get_stop_reason())
  end)
end)
