local commands = require("vibing.application.chat.commands")

---@class Vibing.Completion
local M = {}

---@return string?
---@return boolean
---@return number
function M._get_command_context()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  local before_cursor = line:sub(1, col)

  local slash_pos = before_cursor:match("^.*()/%s*$")
  if slash_pos then
    return nil, false, slash_pos
  end

  local cmd_start, cmd_name = before_cursor:match("^.*()/%s*([%w_-]*)$")
  if cmd_start and cmd_name then
    return cmd_name, false, cmd_start
  end

  local arg_start, full_cmd = before_cursor:match("^.*()/%s*([%w_-]+)%s+[%w_-]*$")
  if arg_start and full_cmd then
    local arg_col = before_cursor:match("^.*/%s*" .. full_cmd .. "%s+()")
    if arg_col then
      return full_cmd, true, arg_col - 1
    end
  end

  return nil, false, 0
end

---@param findstart 0|1
---@param base string
---@return number|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local _, _, start_col = M._get_command_context()
    return start_col
  else
    local command_name, is_argument, _ = M._get_command_context()

    if is_argument and command_name then
      return M._get_argument_completions(command_name, base)
    else
      return M._get_command_completions(base)
    end
  end
end

---@param base string
---@return table[]
function M._get_command_completions(base)
  local all_commands = commands.list_all()
  local completions = {}

  for name, cmd in pairs(all_commands) do
    if base == "" or name:lower():find("^" .. vim.pesc(base:lower())) then
      local kind = "[vibing]"
      if cmd.source == "project" then
        kind = "[custom:project]"
      elseif cmd.source == "user" then
        kind = "[custom:user]"
      end

      table.insert(completions, {
        word = name,
        menu = cmd.description,
        kind = kind,
      })
    end
  end

  table.sort(completions, function(a, b)
    return a.word < b.word
  end)

  return completions
end

---@param command_name string
---@param base string
---@return table[]
function M._get_argument_completions(command_name, base)
  local arg_options = commands.get_argument_completions(command_name)
  if not arg_options then
    return {}
  end

  local completions = {}
  for _, option in ipairs(arg_options) do
    if base == "" or option:lower():find("^" .. vim.pesc(base:lower())) then
      table.insert(completions, {
        word = option,
        menu = string.format("Argument for /%s", command_name),
        kind = "[arg]",
      })
    end
  end

  return completions
end

---@param buf number
function M.setup_buffer(buf)
  vim.bo[buf].omnifunc = "v:lua.require('vibing.application.chat.completion').omnifunc"
end

return M
