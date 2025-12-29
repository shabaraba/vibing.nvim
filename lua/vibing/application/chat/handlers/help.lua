local notify = require("vibing.core.utils.notify")
local commands = require("vibing.application.chat.commands")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid chat buffer")
    return false
  end

  local all_commands = commands.list_all()
  local builtin = {}
  local project = {}
  local user = {}

  for name, cmd in pairs(all_commands) do
    if cmd.source == "builtin" then
      table.insert(builtin, cmd)
    elseif cmd.source == "project" then
      table.insert(project, cmd)
    elseif cmd.source == "user" then
      table.insert(user, cmd)
    end
  end

  table.sort(builtin, function(a, b) return a.name < b.name end)
  table.sort(project, function(a, b) return a.name < b.name end)
  table.sort(user, function(a, b) return a.name < b.name end)

  local lines = {
    "",
    "# Available Slash Commands",
    "",
  }

  if #builtin > 0 then
    table.insert(lines, "## Built-in Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(builtin) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  if #project > 0 then
    table.insert(lines, "## Project Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(project) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  if #user > 0 then
    table.insert(lines, "## User Commands")
    table.insert(lines, "")
    for _, cmd in ipairs(user) do
      table.insert(lines, string.format("- `/%s` - %s", cmd.name, cmd.description))
    end
    table.insert(lines, "")
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)

  notify.info("Help displayed")
  return true
end
