---@class Vibing.CmpAdapter
---nvim-cmp source adapter for vibing completion
---@module "vibing.infrastructure.completion.adapters.cmp"
local M = {}

local slash_source = require("vibing.application.completion.sources.slash")
local file_source = require("vibing.application.completion.sources.file")

---@type table[]
local sources = { slash_source, file_source }

---Create nvim-cmp source
---@return table
function M.create()
  local source = {}

  function source:new()
    return setmetatable({}, { __index = source })
  end

  function source:get_debug_name()
    return "vibing"
  end

  function source:is_available()
    return vim.bo.filetype == "vibing"
  end

  function source:get_trigger_characters()
    return { "/", ":" }
  end

  function source:get_keyword_pattern()
    return [[\%(@file:\)\?\k*]]
  end

  ---@param params table
  ---@param callback fun(response: table)
  function source:complete(params, callback)
    local line = params.context.cursor_line
    local col = params.context.cursor.col

    -- Try each source in order
    for _, src in ipairs(sources) do
      local context = src.get_trigger_context(line, col)
      if context then
        src.get_candidates(context, function(items)
          local cmp_items = M._to_cmp_items(items, context)
          callback({
            items = cmp_items,
            isIncomplete = false,
          })
        end)
        return
      end
    end

    callback({ items = {}, isIncomplete = false })
  end

  return source
end

---Convert vibing items to nvim-cmp format
---@param items Vibing.CompletionItem[]
---@param context Vibing.TriggerContext
---@return table[]
function M._to_cmp_items(items, context)
  local cmp = require("cmp")
  local cmp_items = {}

  for _, item in ipairs(items) do
    local kind = cmp.lsp.CompletionItemKind.Text
    if item.kind == "File" then
      kind = cmp.lsp.CompletionItemKind.File
    elseif item.kind == "Command" then
      kind = cmp.lsp.CompletionItemKind.Function
    elseif item.kind == "Skill" then
      kind = cmp.lsp.CompletionItemKind.Module
    elseif item.kind == "Argument" then
      kind = cmp.lsp.CompletionItemKind.EnumMember
    end

    local insert_text = item.insertText or item.word
    if context.trigger == "slash" then
      insert_text = item.word
    end

    table.insert(cmp_items, {
      label = item.label,
      kind = kind,
      detail = item.detail,
      documentation = item.description,
      insertText = insert_text,
      filterText = item.filterText or item.word,
      sortText = item.word,
    })
  end

  return cmp_items
end

---Register vibing source with nvim-cmp
function M.setup()
  local has_cmp, cmp = pcall(require, "cmp")
  if not has_cmp then
    return false
  end

  cmp.register_source("vibing", M.create())
  return true
end

return M
