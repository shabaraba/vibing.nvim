---@class Vibing.CommandsProvider
---Provides slash command candidates from builtin and custom commands
---@module "vibing.infrastructure.completion.providers.commands"
local M = {}

---Get all command candidates
---@return Vibing.CompletionItem[]
function M.get_all()
  local commands = require("vibing.application.chat.commands")
  local all_commands = commands.list_all()

  local items = {}
  for name, cmd in pairs(all_commands) do
    local source = cmd.source or "builtin"
    local detail = source

    if cmd.plugin_name then
      detail = cmd.plugin_name
    end

    table.insert(items, {
      word = name,
      label = "/" .. name,
      kind = "Command",
      description = cmd.description,
      detail = detail,
      source = source,
      filterText = name,
    })
  end

  table.sort(items, function(a, b)
    return a.word < b.word
  end)

  return items
end

---Get argument completions for a command
---@param command_name string
---@return Vibing.CompletionItem[]
function M.get_arguments(command_name)
  local commands = require("vibing.application.chat.commands")
  local arg_options = commands.get_argument_completions(command_name)

  if not arg_options then
    return {}
  end

  local items = {}
  for _, option in ipairs(arg_options) do
    table.insert(items, {
      word = option,
      label = option,
      kind = "Argument",
      description = string.format("Argument for /%s", command_name),
      source = "builtin",
      filterText = option,
    })
  end

  return items
end

return M
