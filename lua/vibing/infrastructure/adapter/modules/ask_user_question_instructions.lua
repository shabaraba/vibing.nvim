--- How every backend is told to ask the user a multiple-choice question.
---
--- The model writes the question as a fenced block at the end of its reply and stops; vibing.nvim
--- draws the options and the user's answer is the next message
--- (`presentation/chat/modules/question_block.lua` parses it). No tool is involved, so the same
--- lines go to every backend — Grok included — and they carry no per-chat value: nothing in them
--- changes between turns, which keeps the system prompt byte-stable for the prompt cache (#469).
--- @module vibing.infrastructure.adapter.modules.ask_user_question_instructions

local M = {}

--- The fence's info string. The one definition both the instruction and the parser read.
M.FENCE = "vibing-question"

---@return string[]
function M.lines()
  return {
    "When you need the user to choose among options (single or multi-select), do not ask in free "
      .. "text and do not use the native AskUserQuestion tool (it is unavailable here). Instead, end "
      .. "your reply with exactly one fenced code block whose info string is "
      .. M.FENCE
      .. ', containing JSON: {"questions": [{"question": "...", "multiSelect": false, "options": '
      .. '[{"label": "...", "description": "..."}]}]}. Write nothing after the block and stop: '
      .. "vibing.nvim shows the options to the user, and their answer arrives as the next message.",
  }
end

--- The chat's own buffer number, as a line of the system prompt.
---
--- Not part of asking a question any more, but it used to ride along with that instruction and
--- other things still read it: the orchestration skills pass it as `from_bufnr`, and
--- `vibing-chat-recall` finds the chat by it. It is the buffer number rather than the file path
--- because a rename (`:VibingSetFileTitle`) would otherwise change the prompt mid-conversation and
--- invalidate the cache (#489).
---@param chat_bufnr number|nil
---@return string[] empty when there is no chat
function M.chat_buffer_lines(chat_bufnr)
  if not chat_bufnr then
    return {}
  end
  return { "Current vibing.nvim chat buffer number: " .. tostring(chat_bufnr) }
end

return M
