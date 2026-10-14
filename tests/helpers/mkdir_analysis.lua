--- The analysis behind tests/lua/mkdir_call_sites_spec.lua: which `vim.fn.mkdir` call sites in
--- a Lua source create a path unique to this process.
---
--- Why the rule exists, and what the two remedies are, is stated in that spec.
--- @module tests.helpers.mkdir_analysis

local M = {}

local MKDIR = "vim.fn.mkdir("
M.MKDIR = MKDIR
local UNIQUE_ROOT = "vim.fn.tempname()"
local WAIVER = "mkdir%-ok:"

-- Path helpers that return a piece of the path handed to them, so the argument is what decides
-- whether the result is unique.
local WRAPPERS = { "vim.fn.fnamemodify(", "vim.fs.dirname(", "vim.fn.resolve(" }

--- The text of the first argument in `s`, which begins just past an opening parenthesis.
---@param s string
---@return string
local function first_argument(s)
  local depth = 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      if depth == 0 then
        return s:sub(1, i - 1)
      end
      depth = depth - 1
    elseif c == "," and depth == 0 then
      return s:sub(1, i - 1)
    end
  end
  return s
end

--- The identifier a path expression is rooted at; nil for a literal, a call or a `vim.*` value.
---@param expr string
---@return string?
local function root_identifier(expr)
  local e = vim.trim(expr)
  local unwrapped = true
  while unwrapped do
    unwrapped = false
    for _, wrapper in ipairs(WRAPPERS) do
      if e:sub(1, #wrapper) == wrapper then
        e = vim.trim(first_argument(e:sub(#wrapper + 1)))
        unwrapped = true
        break
      end
    end
  end
  local name = e:match("^([A-Za-z_][A-Za-z0-9_]*)")
  return name ~= "vim" and name or nil
end

--- Every `name = rhs` in `lines`, in source order.
---@param lines string[]
---@return { line: integer, name: string, rhs: string }[]
local function assignments(lines)
  local found = {}
  for number, line in ipairs(lines) do
    local name, rhs = line:match("^%s*local%s+([%w_]+)%s*=%s*(.+)$")
    if not name then
      name, rhs = line:match("^%s*([%w_]+)%s*=%s*(.+)$")
    end
    if name then
      table.insert(found, { line = number, name = name, rhs = rhs })
    end
  end
  return found
end

--- Whether the value `name` holds at `before` is provably rooted at `vim.fn.tempname()`.
---
--- Resolution is the nearest assignment above the use, not every assignment in the file. Scope
--- is not tracked -- a spec has one `local test_dir` per `it` block and they are all the same
--- name here -- so the alternatives are "the nearest one" and "all of them". All of them turns
--- every file with one unavoidable shared path into a file where nothing can be proved; the
--- nearest one is what Lua itself would resolve for the shapes this repository writes, and it
--- still reports the call that was left behind when its neighbours were fixed.
---@param name string
---@param before integer
---@param assigned { line: integer, name: string, rhs: string }[]
---@param depth integer?
---@return boolean
local function is_unique(name, before, assigned, depth)
  if (depth or 0) > 8 then
    return false
  end
  local nearest
  for _, entry in ipairs(assigned) do
    if entry.name == name and entry.line < before then
      nearest = entry
    end
  end
  if not nearest then
    return false
  end
  if nearest.rhs:find(UNIQUE_ROOT, 1, true) then
    return true
  end
  local root = root_identifier(nearest.rhs)
  return root ~= nil and is_unique(root, nearest.line, assigned, (depth or 0) + 1)
end

--- The `vim.fn.mkdir` lines in `lines` whose path is not provably unique to this process.
---@param lines string[]
---@return { line: integer, expr: string }[]
function M.unproven_calls(lines)
  local assigned = assignments(lines)
  local found = {}
  for number, line in ipairs(lines) do
    local at = line:find(MKDIR, 1, true)
    local waived = line:find(WAIVER) or (lines[number - 1] or ""):find(WAIVER)
    if at and not waived then
      local expr = first_argument(line:sub(at + #MKDIR))
      local root = root_identifier(expr)
      if
        not expr:find(UNIQUE_ROOT, 1, true)
        and not (root and is_unique(root, number, assigned))
      then
        table.insert(found, { line = number, expr = vim.trim(expr) })
      end
    end
  end
  return found
end

return M
