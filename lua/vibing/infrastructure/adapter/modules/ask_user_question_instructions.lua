--- How every backend is told to ask the user a multiple-choice question, and to ask for a
--- confirmation before work it is about to do.
---
--- Two forms, chosen by whether this turn can reach the bundled MCP server:
---
--- - **Reachable:** the model calls `nvim_ask_question` / `nvim_request_approval`. The call does not
---   wait: it queues an entry on the turn and returns at once, so the model ends its turn and the
---   prompt is drawn when the turn ends (`rpc/handlers/prompt.lua`). A tool call has no position in
---   the text, and its arguments are checked against a schema before anything is drawn.
--- - **Unreachable:** the fenced block fallback, unchanged. `presentation/chat/modules/question_block.lua`
---   parses it, and it is still the only route for a backend with no MCP server (Copilot, Pi, and the
---   oneshot half of Grok and Command Code).
---
--- The lines carry no per-chat value, so a backend that keeps them in a cached prefix stays
--- byte-stable across turns (#469). Names only, never a prefix: claude, codex and grok spell the
--- same tool differently.
--- @module vibing.infrastructure.adapter.modules.ask_user_question_instructions

local M = {}

--- The fence's info string. The one definition both the fallback instruction and the parser read.
M.FENCE = "vibing-question"

--- The tools this module names when the bundled server is reachable. Kept here next to the
--- instruction that names them, as `FENCE` is.
M.ASK_TOOL = "nvim_ask_question"
M.APPROVAL_TOOL = "nvim_request_approval"

--- @param tool boolean whether this turn reaches the bundled MCP server
--- @return string[]
function M.lines(tool)
  if tool then
    return {
      "When you need the user to choose among options (single or multi-select), call the "
        .. M.ASK_TOOL
        .. " tool and then end your turn. It returns immediately — nothing is shown until your turn "
        .. "ends — so do not wait for an answer in the same turn and do not use the native "
        .. "AskUserQuestion / question tool. vibing.nvim shows the options and the user's answer "
        .. "arrives as the next message.",
      "When you are about to do something the user should confirm first (for example, deleting "
        .. "files), call the "
        .. M.APPROVAL_TOOL
        .. " tool with what you intend to do, then end your turn. It returns immediately too, and "
        .. "the confirmation is shown with your reply; the next message is the answer. It is not a "
        .. "tool-permission grant and does not authorise a later tool call.",
    }
  end

  return {
    "When you need the user to choose among options (single or multi-select), do not ask in free "
      .. "text and do not use the native AskUserQuestion / question tool (it is unavailable here). Instead, end "
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
