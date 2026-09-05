---@class Vibing.Toml
---Renders Lua values as TOML *values*, for the `-c key=value` overrides the codex CLI takes.
---
---Deliberately not a TOML serializer: the callers hand codex one scalar, one array of strings
---or one flat table of strings per flag, and the value side of `-c` is the only place TOML
---syntax is parsed at all. The key side is not -- codex splits the dotted path on `.` and takes
---each segment literally, so `mcp_servers."probe-x".command` registers a server named
---`"probe-x"`, quotes included (measured against codex 0.153). `is_bare_key` exists so a caller
---can refuse a segment that would need quoting instead of emitting a key that silently means
---something else.
---@module "vibing.core.utils.toml"
local M = {}

---Whether `segment` can stand unquoted as a TOML key, and therefore as one segment of a codex
---`-c` dotted path.
---@param segment any
---@return boolean
function M.is_bare_key(segment)
  return type(segment) == "string" and segment:match("^[%w_%-]+$") ~= nil
end

---A TOML basic string: double-quoted, with `"`, `\` and every control character escaped.
---
---Newlines become `\n` rather than a multi-line literal, because the whole override travels as
---one argv element and codex parses it as a single TOML value. Verified to round-trip quotes,
---backslashes, tabs, newlines and multibyte text against codex 0.153 (`codex debug
---prompt-input -c developer_instructions=...`).
---@param s string
---@return string
function M.string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\t" then
      return "\\t"
    elseif c == "\r" then
      return "\\r"
    end
    return string.format("\\u%04X", c:byte())
  end)
  return '"' .. escaped .. '"'
end

---A TOML array of basic strings. Non-string entries are rendered through `tostring`, since the
---one caller feeds it a manifest's `args`, where a stray number is a typo rather than a type.
---@param list any[]
---@return string
function M.string_array(list)
  local parts = {}
  for _, item in ipairs(list) do
    table.insert(parts, M.string(tostring(item)))
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

---A TOML inline table whose values are basic strings, keys sorted so the output is stable
---across turns (the codex argv feeds a prompt cache that matches on a byte-stable prefix).
---
---Inline-table keys *are* parsed as TOML, unlike the dotted path, so a key that is not bare is
---quoted rather than refused.
---@param map table<string, any>
---@return string
function M.string_table(map)
  local keys = vim.tbl_keys(map)
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local rendered_key = M.is_bare_key(key) and key or M.string(key)
    table.insert(parts, rendered_key .. " = " .. M.string(tostring(map[key])))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

return M
