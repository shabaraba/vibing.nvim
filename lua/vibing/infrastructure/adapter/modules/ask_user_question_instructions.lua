--- Shared prompt text for the vibing.nvim choice-list MCP tool.
--- @module vibing.infrastructure.adapter.modules.ask_user_question_instructions

local M = {}

local CHAT_BUFFER_LABEL = "Current vibing.nvim chat buffer number"

--- Tell a backend how to invoke the shared choice-list tool and, when available, identify the
--- chat that should receive it. Keeping the instruction and its value together prevents one
--- backend from accidentally emitting only half of the routing contract.
---@param tool_name string backend-specific fully qualified MCP tool name
---@param chat_bufnr number|nil
---@return string[]
function M.lines(tool_name, chat_bufnr)
  local lines = {
    "When you need the user to choose among options (single or multi-select), always call the "
      .. tool_name
      .. " tool instead of asking in free text. Do not use the native AskUserQuestion tool for this — "
      .. "it is unavailable in this environment. Pass this turn's \""
      .. CHAT_BUFFER_LABEL
      .. "\" (given below when available) as the chat_bufnr argument.",
  }
  if chat_bufnr then
    table.insert(lines, CHAT_BUFFER_LABEL .. ": " .. tostring(chat_bufnr))
  end
  return lines
end

return M
