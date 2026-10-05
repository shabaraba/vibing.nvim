--- A multiple-choice question is a fenced block the model writes as the last thing in its reply.
--- These pin what counts as one, because a block recognised where it should not be draws a live
--- prompt out of an example, and one missed leaves the user with JSON and nothing to answer.
local QuestionBlock = require("vibing.presentation.chat.modules.question_block")

local JSON = '{"questions": [{"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}]}'

---@param body string[]
---@return string[]
local function reply(body)
  local lines = { "Some reasoning first.", "" }
  vim.list_extend(lines, body)
  return lines
end

describe("question_block.find_trailing", function()
  it("finds a block that ends the reply, and says where it is", function()
    local lines = reply({ "```vibing-question", JSON, "```" })
    local questions, first, last = QuestionBlock.find_trailing(lines)

    assert.is_not_nil(questions)
    assert.equals("Which?", questions[1].question)
    assert.equals("B", questions[1].options[2].label)
    assert.equals(3, first)
    assert.equals(5, last)
  end)

  it("allows trailing blank lines after the closing fence", function()
    local questions = QuestionBlock.find_trailing(reply({ "```vibing-question", JSON, "```", "", "  " }))

    assert.is_not_nil(questions)
  end)

  it("accepts a bare array of questions", function()
    local bare = '[{"question": "Which?", "options": [{"label": "A"}]}]'
    local questions = QuestionBlock.find_trailing(reply({ "```vibing-question", bare, "```" }))

    assert.equals("A", questions[1].options[1].label)
  end)

  it("ignores a block followed by more prose: the turn did not stop on it", function()
    local lines = reply({ "```vibing-question", JSON, "```", "", "Then I carried on." })

    assert.is_nil(QuestionBlock.find_trailing(lines))
  end)

  it("ignores a reply that ends with some other code block", function()
    -- An example of the format quoted earlier must not become a live prompt because a later,
    -- unrelated code block happens to close the reply.
    local lines = reply({ "```vibing-question", JSON, "```", "", "```lua", "print(1)", "```" })

    assert.is_nil(QuestionBlock.find_trailing(lines))
  end)

  it("ignores a block that is not valid JSON", function()
    assert.is_nil(QuestionBlock.find_trailing(reply({ "```vibing-question", "{not json", "```" })))
  end)

  it("ignores a question with no options", function()
    local empty = '{"questions": [{"question": "Which?", "options": []}]}'

    assert.is_nil(QuestionBlock.find_trailing(reply({ "```vibing-question", empty, "```" })))
  end)

  it("ignores an option with no label", function()
    local unlabeled = '{"questions": [{"question": "Which?", "options": [{"description": "x"}]}]}'

    assert.is_nil(QuestionBlock.find_trailing(reply({ "```vibing-question", unlabeled, "```" })))
  end)

  it("uses the same fence name it tells the model to write", function()
    local Instructions = require("vibing.infrastructure.adapter.modules.ask_user_question_instructions")

    assert.equals(Instructions.FENCE, QuestionBlock.FENCE)
    assert.is_truthy(table.concat(Instructions.lines(), "\n"):find(QuestionBlock.FENCE, 1, true))
  end)
end)
