---@diagnostic disable: undefined-field
--- The chat side of a question: the block the turn ended on becomes choices in the next unsent
--- section, and the raw JSON leaves the transcript so the question is not shown twice.
local ChatBuffers = require("tests.helpers.chat_buffers")

local JSON = '{"questions": [{"question": "Which approach?", "options": [{"label": "Fast"}, {"label": "Safe"}]}]}'

describe("ChatBuffer:take_question_block", function()
  local view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
  end)

  after_each(function()
    ChatBuffers.reset()
  end)

  ---@param body string[]
  ---@return Vibing.ChatBuffer
  local function chat_whose_turn_wrote(body)
    local chat_buf = view.render({ session_id = "question" }, "back")
    chat_buf:start_response()
    chat_buf:append_chunk(table.concat(body, "\n") .. "\n")
    -- Streamed text sits in `_chunk_parts` until a timer flushes it; flush now so the buffer holds
    -- what the turn wrote before anything is compared.
    chat_buf:_flush_chunks()
    return chat_buf
  end

  ---@param chat_buf Vibing.ChatBuffer
  ---@return string
  local function text(chat_buf)
    return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
  end

  it("turns the block into choices drawn in the next unsent section", function()
    local chat_buf = chat_whose_turn_wrote({ "Two ways to do it.", "", "```vibing-question", JSON, "```" })

    assert.is_true(chat_buf:take_question_block())
    chat_buf:add_user_section()

    local buffer = text(chat_buf)
    assert.is_truthy(buffer:find("1. Fast", 1, true), buffer)
    assert.is_truthy(buffer:find("2. Safe", 1, true), buffer)
    assert.is_truthy(buffer:find("Two ways to do it.", 1, true), "the reply above the block stays")
  end)

  it("takes the raw block out of the transcript", function()
    local chat_buf = chat_whose_turn_wrote({ "Two ways to do it.", "", "```vibing-question", JSON, "```" })

    chat_buf:take_question_block()

    local buffer = text(chat_buf)
    assert.is_nil(buffer:find("vibing-question", 1, true), buffer)
    assert.is_nil(buffer:find('"questions"', 1, true), buffer)
  end)

  it("reports the chat as having asked a question", function()
    local chat_buf = chat_whose_turn_wrote({ "```vibing-question", JSON, "```" })

    chat_buf:take_question_block()

    assert.equals("asked_question", chat_buf:get_stop_reason())
  end)

  it("leaves a reply with no block alone", function()
    local chat_buf = chat_whose_turn_wrote({ "Just an answer." })
    local before = text(chat_buf)

    assert.is_false(chat_buf:take_question_block())
    assert.equals(before, text(chat_buf))
    assert.is_nil(chat_buf:get_stop_reason())
  end)

  it("draws the choices once, then forgets them", function()
    -- The answer is the next turn's message, so a second redraw (the next turn's end) must not
    -- bring the same options back.
    local chat_buf = chat_whose_turn_wrote({ "```vibing-question", JSON, "```" })
    chat_buf:take_question_block()
    chat_buf:add_user_section()

    assert.is_nil(chat_buf._pending_choices)
  end)
end)
