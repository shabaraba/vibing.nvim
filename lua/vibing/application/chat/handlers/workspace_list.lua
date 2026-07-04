local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")

---@param chat_buffer Vibing.ChatBuffer
---@param lines string[]
local function append_to_buffer(chat_buffer, lines)
  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return true
  end

  local status = (args[1] == "done") and "done" or "active"
  local workspaces = Manager.list(status)

  local lines = { "", string.format("# Workspaces (%s)", status), "" }
  if #workspaces == 0 then
    table.insert(lines, string.format("No %s workspaces.", status))
  else
    for _, ws in ipairs(workspaces) do
      table.insert(lines, string.format("- `%s` - %s (%s)", ws.id, ws.description or "", ws.branch or ""))
    end
  end
  table.insert(lines, "")

  append_to_buffer(chat_buffer, lines)

  return true
end
