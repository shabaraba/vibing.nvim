---@class Vibing.YamlFrontmatter
---Reads single top-level scalars out of a markdown file's YAML frontmatter.
---
---Deliberately not a YAML parser: the callers (skill and agent completion) want two or three
---known keys out of a handful of lines, and pulling in a real parser to read `description:`
---would cost more than it explains. What it does handle is the one construct a line-anchored
---`^key:%s*(.+)$` gets wrong -- block scalars. `description: >-` matches that pattern and
---captures ">-", so a skill that wraps a long description across lines had ">-" as its entire
---description in the `/` picker.
---@module "vibing.core.utils.yaml_frontmatter"
local M = {}

---A block scalar header: `|` or `>` plus an optional indent and chomping indicator, in either
---order (`>`, `>-`, `|2`, `>-2`).
---@param value string
---@return boolean
local function is_block_header(value)
  return value:match("^[|>]%d?[-+]?$") ~= nil or value:match("^[|>][-+]%d?$") ~= nil
end

---Read one top-level frontmatter key.
---
---Continuation lines are joined with a space for `|` as well as `>`, because every consumer of
---this puts the value in a completion item's `description`, and `omnifunc`'s `menu` field is a
---single line -- a literal block's newlines have nowhere to go.
---@param lines string[] whole-file lines; the frontmatter must open on the first one
---@param key string
---@return string? value, or nil when there is no frontmatter, the key is absent, or it is empty
function M.read(lines, key)
  if not lines or lines[1] ~= "---" then
    return nil
  end

  local value = nil
  local collecting = false

  for i = 2, #lines do
    local line = lines[i]
    if line == "---" then
      break
    end

    local found_key, inline = line:match("^([%w%-_]+):%s*(.*)$")
    if found_key then
      -- Column 0 is the next top-level key, which ends the block we were collecting.
      if collecting then
        break
      end
      if found_key == key then
        if is_block_header(inline) then
          value, collecting = "", true
        else
          value = inline
          break
        end
      end
    elseif collecting and line:match("^%s+%S") then
      local continued = vim.trim(line)
      value = value == "" and continued or (value .. " " .. continued)
    end
  end

  return value ~= "" and value or nil
end

return M
