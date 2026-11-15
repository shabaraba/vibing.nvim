--- A multiple-choice question written at the end of a reply: the fallback route, parsed here.
---
--- Where a backend's transport registers the bundled MCP server the model is told to call
--- `nvim_ask_question` instead, and this parser never sees a block. This module remains for the
--- backends that cannot reach that server (Copilot, Pi, and the oneshot half of Grok and Command
--- Code), and for a model that writes a block anyway. Both routes end in `insert_choices`.
---
--- The model ends its turn with one fenced block:
---
---     ```vibing-question
---     {"questions": [{"question": "...", "multiSelect": false,
---                     "options": [{"label": "...", "description": "..."}]}]}
---     ```
---
--- and vibing.nvim draws the choices into the next unsent `## User` section, where the user
--- answers with ordinary editing. The answer is the next turn's message.
---
--- **The block is recognised only as the last thing the turn wrote.** A question asked mid-turn and
--- then followed by more work is not a question the turn stopped on, and a block quoted inside an
--- earlier part of the answer (an example, a code review) must not be drawn as a live prompt. That
--- condition is the route's weakness and the reason the tool is preferred: an unrelated instruction
--- that makes the model append something afterwards loses the question
--- (`handbook/architecture/queued-prompt-tools.md`).
--- @module vibing.presentation.chat.modules.question_block

local M = {}

--- The fence's info string, defined next to the instruction that asks for it.
M.FENCE = require("vibing.infrastructure.adapter.modules.ask_user_question_instructions").FENCE

--- How many questions one request may carry. The cap `AskUserQuestion` had, kept for the tool and
--- the merged queue alike: they are drawn as one block, and a question nobody was shown is worse
--- than a call the model can correct.
M.MAX_QUESTIONS = 4

--- Whether one question entry has the shape the renderer can draw.
--- @param q any
--- @return boolean
function M.is_question(q)
  if type(q) ~= "table" or type(q.options) ~= "table" or #q.options == 0 then
    return false
  end
  for _, opt in ipairs(q.options) do
    if type(opt) ~= "table" or type(opt.label) ~= "string" or opt.label == "" then
      return false
    end
  end
  return q.question == nil or type(q.question) == "string"
end

--- Validate a question list, whether it arrived as JSON in a block body or as a tool argument.
---
--- **The one definition of what a question is**, shared by the fence parser and the
--- `nvim_ask_question` tool handler. A block that fails this stays in the transcript as the model
--- wrote it, and a tool call that fails it is refused before anything is drawn.
--- @param value any `{"questions": [...]}`, a bare question list, or a decoded block body
--- @return table[]? questions
--- @return string? error human-readable reason the value is not a question list
function M.validate(value)
  if type(value) ~= "table" then
    return nil, "questions must be a list"
  end
  local questions = value.questions or value
  if type(questions) ~= "table" or #questions == 0 then
    return nil, "questions must be a non-empty list"
  end
  for index, q in ipairs(questions) do
    if not M.is_question(q) then
      return nil, string.format(
        "question %d needs an options list, and every option needs a non-empty label",
        index
      )
    end
  end
  return questions
end

--- Decode a block body into the question list, or nil when it is not one.
---
--- Accepts the documented `{"questions": [...]}` and a bare array, since both are what a model
--- writes when told "a list of questions".
--- @param body string
--- @return table[]?
local function decode(body)
  local ok, value = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    return nil
  end
  local questions = M.validate(value)
  return questions
end

--- Find a question block that ends the given lines.
---
--- Only trailing blank lines may follow the closing fence (see the module comment). Returns the
--- 1-based inclusive range of the block within `lines` so the caller can take it out of the
--- transcript once it has been drawn as choices — leaving the JSON in place would show the same
--- question twice, once as JSON and once as options.
--- @param lines string[]
--- @return table[]? questions
--- @return integer? first line of the opening fence
--- @return integer? last line of the closing fence
function M.find_trailing(lines)
  local last = #lines
  while last > 0 and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  if last == 0 or vim.trim(lines[last]) ~= "```" then
    return nil
  end

  -- Walking past another code block to an earlier question fence is harmless: the body would then
  -- hold that block's fence lines, which no JSON can contain, so `decode` refuses it.
  local open_pattern = "^%s*```%s*" .. vim.pesc(M.FENCE) .. "%s*$"
  for first = last - 1, 1, -1 do
    local line = lines[first]
    if line:match(open_pattern) then
      local questions = decode(table.concat(lines, "\n", first + 1, last - 1))
      if not questions then
        return nil
      end
      return questions, first, last
    end
  end
  return nil
end

return M
