---@class Vibing.CmpAdapter
---nvim-cmp source adapter for vibing completion
---@module "vibing.infrastructure.completion.adapters.cmp"
local M = {}

local slash_source = require("vibing.application.completion.sources.slash")
local file_source = require("vibing.application.completion.sources.file")
local agent_source = require("vibing.application.completion.sources.agent")
local frontmatter_source = require("vibing.application.completion.sources.frontmatter")
local chat_view = require("vibing.presentation.chat.view")

---@type table[]
local sources = { frontmatter_source, slash_source, file_source, agent_source }

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
    return chat_view.is_current_buffer_chat()
  end

  function source:get_trigger_characters()
    return { "/", ":", "@" }
  end

  function source:get_keyword_pattern()
    return [[\%(@\%(file\|agent\):\)\?\k*]]
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

---Map vibing kind to nvim-cmp CompletionItemKind
---@param kind string
---@param cmp_kinds table
---@return number
local function to_cmp_kind(kind, cmp_kinds)
  local kind_map = {
    File = cmp_kinds.File,
    Command = cmp_kinds.Function,
    Skill = cmp_kinds.Module,
    Agent = cmp_kinds.Interface,
    Argument = cmp_kinds.EnumMember,
    Enum = cmp_kinds.Enum,
    Tool = cmp_kinds.Class,
    Pattern = cmp_kinds.Constant,
  }
  return kind_map[kind] or cmp_kinds.Text
end

---Convert vibing items to nvim-cmp format
---@param items Vibing.CompletionItem[]
---@param context Vibing.TriggerContext
---@return table[]
function M._to_cmp_items(items, context)
  local cmp_kinds = require("cmp").lsp.CompletionItemKind
  local cmp_items = {}

  for _, item in ipairs(items) do
    local insert_text = item.word
    if context.trigger ~= "slash" and item.insertText then
      insert_text = item.insertText
    end

    table.insert(cmp_items, {
      label = item.label,
      kind = to_cmp_kind(item.kind, cmp_kinds),
      documentation = {
        kind = "markdown",
        value = item.description or "",
      },
      insertText = insert_text,
      filterText = item.label,
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
