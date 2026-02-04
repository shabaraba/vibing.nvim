---@class Vibing.FrontmatterSource
---Completion source for YAML frontmatter fields
---@module "vibing.application.completion.sources.frontmatter"
local M = {}

M.name = "frontmatter"

local frontmatter_provider = require("vibing.infrastructure.completion.providers.frontmatter")

---Detect trigger context for frontmatter fields
---@param line string Current line content
---@param col number Cursor column (0-indexed)
---@return Vibing.TriggerContext?
function M.get_trigger_context(line, col)
  local before_cursor = line:sub(1, col)
  local before_cursor_plus = line:sub(1, col + 1) -- Include next char for pattern matching

  -- Pattern 1: "mode: " or "model: " or "permission_mode: " (enum fields)
  -- Note: Both "permissions_mode" and "permission_mode" are supported
  for _, field_name in ipairs({ "permissions_mode", "permission_mode", "mode", "model" }) do
    local pattern = "^%s*" .. field_name .. ":%s*(.*)$"
    local value = before_cursor:match(pattern)
    if value then
      -- Normalize field name to "permissions_mode" for provider lookup
      local normalized_field = field_name == "permission_mode" and "permissions_mode" or field_name
      return {
        trigger = "frontmatter_enum",
        field = normalized_field,
        query = value,
        start_col = #before_cursor - #value + 1,
      }
    end
  end

  -- Pattern 2: "permissions_allow:", "permissions_deny:", "permissions_ask:" (tool lists)
  -- Match list items: "  - " followed by optional tool name
  for _, perm_type in ipairs({ "allow", "deny", "ask" }) do
    if before_cursor:match("^%s*permissions_" .. perm_type .. ":%s*$") then
      -- Cursor is at end of field declaration, no completion yet
      return nil
    end
  end

  -- Pattern 3: "Bash(pattern)" - completion inside parentheses for command patterns
  -- Try with plus-one first to catch "Bash(" immediately after typing '('
  local tool_name, pattern_query = before_cursor_plus:match("^%s*%-%s*(%w+)%((.*)$")
  if not tool_name then
    -- Fallback to regular before_cursor
    tool_name, pattern_query = before_cursor:match("^%s*%-%s*(%w+)%((.*)$")
  end

  if tool_name then
    -- Calculate start_col: position after the opening paren
    local before_paren = before_cursor:match("^(.-)%(")
    if not before_paren then
      -- Paren might be at col+1
      before_paren = before_cursor_plus:match("^(.-)%(")
    end
    -- start_col is 0-indexed position after '('
    -- before_paren length gives us the position of '(', add 1 to get position after
    local start_col = before_paren and (#before_paren + 1) or (#before_cursor - #pattern_query + 1)
    return {
      trigger = "frontmatter_pattern",
      tool = tool_name,
      query = pattern_query,
      start_col = start_col,
    }
  end

  -- Pattern 3.5: "Bash" (without parentheses) - offer pattern completion for pattern-enabled tools
  -- This allows completion immediately after typing tool name
  local tool_only = before_cursor:match("^%s*%-%s*(%w+)$")
  if tool_only and frontmatter_provider.has_command_patterns(tool_only) then
    local start_after_dash = before_cursor:match("^%s*%-%s*()") -- Find position after "- "
    return {
      trigger = "frontmatter_pattern",
      tool = tool_only,
      query = "",
      start_col = start_after_dash or 1,
    }
  end

  -- Pattern 4: Tool list items under permissions_* field
  local tool_query = before_cursor:match("^%s*%-%s*(.*)$")
  if tool_query then
    -- Look backwards to find which permissions field we're under
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)

    for i = #lines, 1, -1 do
      for _, perm_type in ipairs({ "allow", "deny", "ask" }) do
        if lines[i]:match("^%s*permissions_" .. perm_type .. ":%s*$") then
          return {
            trigger = "frontmatter_tool",
            field = "permissions_" .. perm_type,
            query = tool_query,
            start_col = #before_cursor - #tool_query + 1,
          }
        end
      end
      -- Stop if we hit another top-level field or frontmatter boundary
      if lines[i]:match("^%w+:") or lines[i]:match("^%-%-%-") then
        break
      end
    end
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
  local query_lower = query:lower()
  return vim.tbl_filter(function(item)
    return item.filterText:lower():find(query_lower, 1, true) ~= nil
  end, items)
end

---Get completion candidates
---@param context Vibing.TriggerContext
---@param callback fun(items: Vibing.CompletionItem[])
function M.get_candidates(context, callback)
  local items = {}

  if context.trigger == "frontmatter_enum" then
    items = frontmatter_provider.get_enum_values(context.field)
  elseif context.trigger == "frontmatter_tool" then
    items = frontmatter_provider.get_tool_names()
  elseif context.trigger == "frontmatter_pattern" then
    items = frontmatter_provider.get_command_patterns(context.tool)
  end

  callback(filter_items(items, context.query))
end

---Get completion candidates synchronously (for omnifunc)
---@param context Vibing.TriggerContext
---@return Vibing.CompletionItem[]
function M.get_candidates_sync(context)
  local items = {}

  if context.trigger == "frontmatter_enum" then
    items = frontmatter_provider.get_enum_values(context.field)
  elseif context.trigger == "frontmatter_tool" then
    items = frontmatter_provider.get_tool_names()
  elseif context.trigger == "frontmatter_pattern" then
    items = frontmatter_provider.get_command_patterns(context.tool)
  end

  return filter_items(items, context.query)
end

return M
