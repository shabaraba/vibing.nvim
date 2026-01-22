---@class Vibing.SlashSource
---Completion source for slash commands and skills
---@module "vibing.application.completion.sources.slash"
local M = {}

M.name = "slash"

local commands_provider = require("vibing.infrastructure.completion.providers.commands")
local skills_provider = require("vibing.infrastructure.completion.providers.skills")

---Detect trigger context for slash commands
---@param line string Current line content
---@param col number Cursor column (0-indexed)
---@return Vibing.TriggerContext?
function M.get_trigger_context(line, col)
  local before_cursor = line:sub(1, col)

  -- Pattern 1: "/command arg" - completing argument
  local cmd_with_arg = before_cursor:match("^%s*/([%w_:-]+)%s+([%w_-]*)$")
  if cmd_with_arg then
    local command_name = before_cursor:match("^%s*/([%w_:-]+)%s+")
    local arg_query = before_cursor:match("%s+([%w_-]*)$") or ""
    local arg_start = before_cursor:find("%s+[%w_-]*$")

    return {
      trigger = "argument",
      query = arg_query,
      start_col = arg_start or col,
      command_name = command_name,
    }
  end

  -- Pattern 2: "/" at line start - completing command/skill name
  local slash_match = before_cursor:match("^%s*/([%w_:-]*)$")
  if slash_match ~= nil then
    local slash_pos = before_cursor:find("/")
    return {
      trigger = "slash",
      query = slash_match,
      start_col = slash_pos,
    }
  end

  return nil
end

---Filter items by query (case-insensitive prefix match on filterText)
---@param items Vibing.CompletionItem[]
---@param query string?
---@return Vibing.CompletionItem[]
local function filter_items(items, query)
  if not query or query == "" then
    return items
  end
  local query_lower = query:lower()
  return vim.tbl_filter(function(item)
    return item.filterText:lower():find(query_lower, 1, true) ~= nil
  end, items)
end

---Get completion candidates
---@param context Vibing.TriggerContext
---@param callback fun(items: Vibing.CompletionItem[])
function M.get_candidates(context, callback)
  if context.trigger == "argument" and context.command_name then
    callback(commands_provider.get_arguments(context.command_name))
    return
  end

  local items = vim.list_extend(commands_provider.get_all(), skills_provider.get_all())
  items = filter_items(items, context.query)

  table.sort(items, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "Command"
    end
    return a.word < b.word
  end)

  callback(items)
end

return M
