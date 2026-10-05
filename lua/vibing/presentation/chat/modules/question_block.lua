--- A multiple-choice question the model asks by writing it, not by calling a tool.
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
--- **Why not a tool call.** The `nvim_ask_user_question` MCP tool held its reply open until the
--- human answered, which needed a withheld-reply registry, a measured ceiling on how late an MCP
--- answer is still consumed, and an exemption from every "this chat is responding" guard. All of
--- that bought one thing over ending the turn: a CLI process that stays alive while the human
--- thinks. A resident process (duplex, the default) already stays alive between turns, and the
--- prompt cache is server-side either way, so the tool's cost no longer bought anything. A block
--- in the text also reaches every backend, Grok included, which never could reach the MCP tool.
---
--- **The block is recognised only as the last thing the turn wrote.** A question asked mid-turn and
--- then followed by more work is not a question the turn stopped on, and a block quoted inside an
--- earlier part of the answer (an example, a code review) must not be drawn as a live prompt.
--- @module vibing.presentation.chat.modules.question_block

local M = {}

--- The fence's info string, defined next to the instruction that asks for it.
M.FENCE = require("vibing.infrastructure.adapter.modules.ask_user_question_instructions").FENCE

--- Whether one question entry has the shape the renderer can draw.
--- @param q any
--- @return boolean
local function is_question(q)
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

--- Decode a block body into the question list, or nil when it is not one.
---
--- Accepts the documented `{"questions": [...]}` and a bare array, since both are what a model
--- writes when told "a list of questions". Anything else is not a question: the block stays in the
--- transcript as the model wrote it, which is the visible failure, rather than a guessed prompt.
--- @param body string
--- @return table[]?
local function decode(body)
  local ok, value = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok or type(value) ~= "table" then
    return nil
  end
  local questions = value.questions or value
  if type(questions) ~= "table" or #questions == 0 then
    return nil
  end
  for _, q in ipairs(questions) do
    if not is_question(q) then
      return nil
    end
  end
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
