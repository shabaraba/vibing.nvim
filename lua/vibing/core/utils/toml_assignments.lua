---Lists the assignments of a TOML document as full dotted paths and raw value text.
---
---Not a TOML parser: values are not decoded, only located, so a caller can hand one back to
---codex verbatim as `-c path=value`, where codex does the parsing. A value spanning lines (a
---multi-line array, inline table or `"""` string) comes back with `raw = nil` rather than as
---its first line, and its continuation lines are never read as assignments of their own.
---@module "vibing.core.utils.toml_assignments"
local M = {}

---@class Vibing.TomlAssignment
---@field path string[] Table header segments followed by the key's own segments
---@field raw string|nil The value's text, or nil when it cannot travel as one `-c` value

---Index just past the string opening at `i`, or nil when it does not close on this line.
---@param line string
---@param i integer
---@return integer|nil
local function string_end(line, i)
  local quote = line:sub(i, i)
  if line:sub(i, i + 2) == quote:rep(3) then
    local _, last = line:find(quote:rep(3), i + 3, true)
    return last and last + 1
  end
  local j = i + 1
  while j <= #line do
    local c = line:sub(j, j)
    if c == quote then
      return j + 1
    end
    j = j + ((quote == '"' and c == "\\") and 2 or 1)
  end
  return nil
end

---The text of a single quoted TOML string, or nil when `raw` is anything else.
---@param raw string|nil
---@return string|nil
function M.decode_string(raw)
  local quote = raw and raw:sub(1, 1)
  if (quote ~= '"' and quote ~= "'") or string_end(raw, 1) ~= #raw + 1 then
    return nil
  end
  if quote == "'" then
    return raw:sub(2, -2)
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  return ok and type(decoded) == "string" and decoded or nil
end

---Each character outside strings, by index; `closed` is false when a string runs past the line.
---@param line string
---@return table<integer, string> chars, boolean closed
local function unquoted(line)
  local chars, i = {}, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' or c == "'" then
      i = string_end(line, i)
      if not i then
        return chars, false
      end
    else
      chars[i] = c
      i = i + 1
    end
  end
  return chars, true
end

---@param chars table<integer, string>
---@param target string
---@return integer|nil
local function first(chars, target)
  local found
  for i, c in pairs(chars) do
    found = c == target and (not found or i < found) and i or found
  end
  return found
end

---@param chars table<integer, string>
---@return integer
local function depth(chars)
  local n = 0
  for _, c in pairs(chars) do
    n = n + ((c == "[" or c == "{") and 1 or (c == "]" or c == "}") and -1 or 0)
  end
  return n
end

---@param s string
---@return string[]|nil
local function parse_key(s)
  local parts, i = {}, 1
  while true do
    i = s:find("%S", i)
    local segment, stop
    if i and (s:sub(i, i) == '"' or s:sub(i, i) == "'") then
      stop = string_end(s, i)
      segment = stop and M.decode_string(s:sub(i, stop - 1))
    elseif i then
      local _, last = s:find("^[%w_%-]+", i)
      stop = last and last + 1
      segment = last and s:sub(i, last)
    end
    if not segment then
      return nil
    end
    table.insert(parts, segment)
    i = s:find("%S", stop)
    if not i then
      return parts
    elseif s:sub(i, i) ~= "." then
      return nil
    end
    i = i + 1
  end
end

---@param lines string[]
---@return Vibing.TomlAssignment[]
function M.scan(lines)
  local result, section, open = {}, {}, nil
  for index, line in ipairs(lines) do
    line = index == 1 and line:gsub("^\239\187\191", "") or line
    local chars, closed = unquoted(line)
    local hash = first(chars, "#")
    for i in pairs(chars) do
      chars[i] = (not hash or i < hash) and chars[i] or nil
    end
    local text = vim.trim(hash and line:sub(1, hash - 1) or line)

    if open == "string" then
      open = not (line:find('"""', 1, true) or line:find("'''", 1, true)) and open or nil
    elseif open then
      open = open + depth(chars)
      open = open > 0 and open or nil
    elseif text:sub(1, 1) == "[" then
      local is_array = text:sub(1, 2) == "[["
      local inner = is_array and text:match("^%[%[(.*)%]%]$") or text:match("^%[(.*)%]$")
      section = inner and parse_key(inner)
      section = section and is_array and vim.list_extend({ "[[]]" }, section) or section
    elseif text ~= "" and section then
      local eq = first(chars, "=")
      local key = eq and parse_key(line:sub(1, eq - 1))
      if key then
        local raw = vim.trim(line:sub(eq + 1, hash and hash - 1 or nil))
        local level = depth(chars)
        open = not closed and "string" or level > 0 and level or nil
        local path = vim.list_extend(vim.list_extend({}, section), key)
        table.insert(result, { path = path, raw = (not open and raw ~= "") and raw or nil })
      end
    end
  end
  return result
end

return M
