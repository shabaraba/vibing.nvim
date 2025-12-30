local notify = require("vibing.core.utils.notify")

---@class Vibing.SlashCommand
---@field name string
---@field handler fun(args: string[], chat_buffer: Vibing.ChatBuffer): boolean
---@field description string

---@class Vibing.CommandRegistry
local M = {}

---@type table<string, Vibing.SlashCommand>
M.commands = {}

---@type table<string, Vibing.SlashCommand>
M.custom_commands = {}

---@param command Vibing.SlashCommand
function M.register(command)
  M.commands[command.name] = command
end

---@param message string
---@return boolean
function M.is_command(message)
  return message:match("^/%w+") ~= nil
end

---@param message string
---@return string?
---@return string[]
function M.parse(message)
  local trimmed = vim.trim(message)
  if not trimmed:match("^/") then
    return nil, {}
  end

  local without_slash = trimmed:sub(2)

  local command_name = without_slash:match("^(%S+)")
  if not command_name then
    return nil, {}
  end

  local args_string = without_slash:sub(#command_name + 1):match("^%s*(.*)$")
  if not args_string or args_string == "" then
    return command_name, {}
  end

  local args = {}
  local current_arg = ""
  local paren_depth = 0

  for i = 1, #args_string do
    local char = args_string:sub(i, i)

    if char == "(" then
      paren_depth = paren_depth + 1
      current_arg = current_arg .. char
    elseif char == ")" then
      paren_depth = math.max(0, paren_depth - 1)
      current_arg = current_arg .. char
    elseif char:match("%s") and paren_depth == 0 then
      if current_arg ~= "" then
        table.insert(args, current_arg)
        current_arg = ""
      end
    else
      current_arg = current_arg .. char
    end
  end

  if current_arg ~= "" then
    table.insert(args, current_arg)
  end

  return command_name, args
end

---@param message string
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
---@return boolean
function M.execute(message, chat_buffer)
  local command_name, args = M.parse(message)

  if not command_name then
    return false, false
  end

  local command = M.commands[command_name]
  local is_custom = false

  if not command then
    command = M.custom_commands[command_name]
    is_custom = command ~= nil
  end

  if not command then
    return false, false
  end

  local success, result = pcall(command.handler, args, chat_buffer)
  if not success then
    notify.error(string.format("Command error: %s", result))
  end

  return true, is_custom
end

---@return Vibing.SlashCommand[]
function M.list()
  local list = {}
  for _, command in pairs(M.commands) do
    table.insert(list, command)
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

---@param content string
---@return boolean
local function has_argument_placeholders(content)
  return content:match("%$ARGUMENTS") ~= nil
    or content:match("{{ARGUMENTS}}") ~= nil
    or content:match("{{%d+}}") ~= nil
end

---@param custom_cmd Vibing.CustomCommand
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
local function execute_custom_command(custom_cmd, args, chat_buffer)
  local message = custom_cmd.content

  local all_args = table.concat(args, " ")

  message = message:gsub("%$ARGUMENTS", function() return all_args end)
  message = message:gsub("{{ARGUMENTS}}", function() return all_args end)

  for i, arg in ipairs(args) do
    message = message:gsub("{{" .. i .. "}}", function() return arg end)
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  if vim.trim(message) == "" then
    notify.error(string.format("Custom command /%s produced empty prompt", custom_cmd.name))
    return false
  end

  vim.schedule(function()
    require("vibing.application.chat.use_case").send(chat_buffer, message)
  end)

  notify.info(string.format("Custom command executed: /%s", custom_cmd.name))
  return true
end

---@param custom_cmd Vibing.CustomCommand
function M.register_custom(custom_cmd)
  local requires_args = has_argument_placeholders(custom_cmd.content)

  M.custom_commands[custom_cmd.name] = {
    name = custom_cmd.name,
    handler = function(args, chat_buffer)
      if requires_args and #args == 0 then
        vim.ui.input({
          prompt = string.format("/%s argument: ", custom_cmd.name),
        }, function(input)
          if input and vim.trim(input) ~= "" then
            local input_args = vim.split(input, "%s+", { trimempty = true })
            execute_custom_command(custom_cmd, input_args, chat_buffer)
          else
            notify.warn(string.format("/%s requires an argument", custom_cmd.name))
          end
        end)
        return true
      end

      return execute_custom_command(custom_cmd, args, chat_buffer)
    end,
    description = custom_cmd.description,
    source = custom_cmd.source,
    requires_args = requires_args,
  }
end

---@return table<string, Vibing.SlashCommand>
function M.list_all()
  local all = {}

  for name, cmd in pairs(M.commands) do
    all[name] = vim.tbl_extend("force", cmd, { source = "builtin" })
  end

  for name, cmd in pairs(M.custom_commands) do
    all[name] = cmd
  end

  return all
end

---@param command_name string
---@return string[]?
function M.get_argument_completions(command_name)
  local completions = {
    mode = { "auto", "plan", "code", "explore" },
    model = { "opus", "sonnet", "haiku" },
  }
  return completions[command_name]
end

return M
