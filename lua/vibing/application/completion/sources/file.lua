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
  local file_match = before_cursor:match("@file:([^%s]*)$")
  if file_match ~= nil then
    local trigger_pos = before_cursor:find("@file:")
    return {
      trigger = "file",
      query = file_match,
      start_col = trigger_pos + 6, -- After "@file:"
    }
  end

  return nil
end

---Filter items by query
---@param items Vibing.CompletionItem[]
---@param query string
---@return Vibing.CompletionItem[]
local function filter_by_query(items, query)
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
    callback(filter_by_query(items, context.query))
  end)
end

---Get completion candidates synchronously (for omnifunc)
---@param context Vibing.TriggerContext
---@return Vibing.CompletionItem[]
function M.get_candidates_sync(context)
  local items = files_provider.get_all_sync()
  return filter_by_query(items, context.query)
end

return M
