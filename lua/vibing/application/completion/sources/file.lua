---@class Vibing.FileSource
---Completion source for @file: references
---@module "vibing.application.completion.sources.file"
local M = {}

M.name = "file"

local files_provider = require("vibing.infrastructure.completion.providers.files")

---Detect trigger context for file paths
---@param line string Current line content
---@param col number Cursor column (0-indexed)
---@return Vibing.TriggerContext?
function M.get_trigger_context(line, col)
  local before_cursor = line:sub(1, col)

  -- Pattern: "@file:" followed by optional path
  -- Use position capture () to get the start of the match
  local trigger_pos, file_match = before_cursor:match("()@file:([^%s]*)$")
  if trigger_pos ~= nil then
    return {
      trigger = "file",
      query = file_match,
      start_col = trigger_pos + 6, -- After "@file:"
    }
  end

  return nil
end

---Filter items by query (substring match)
---@param items Vibing.CompletionItem[]
---@param query string?
---@return Vibing.CompletionItem[]
local function filter_items(items, query)
  if not query or query == "" then
    return items
  end
  return vim.tbl_filter(function(item)
    return item.word:find(query, 1, true) ~= nil
  end, items)
end

---Get completion candidates (async, for nvim-cmp)
---@param context Vibing.TriggerContext
---@param callback fun(items: Vibing.CompletionItem[])
function M.get_candidates(context, callback)
  files_provider.get_all_async(function(items)
    callback(filter_items(items, context.query))
  end)
end

---Get completion candidates synchronously (for omnifunc)
---@param context Vibing.TriggerContext
---@return Vibing.CompletionItem[]
function M.get_candidates_sync(context)
  return filter_items(files_provider.get_all_sync(), context.query)
end

return M
