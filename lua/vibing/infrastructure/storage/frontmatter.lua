local M = {}

local FRONTMATTER_START = "---"
local FRONTMATTER_END = "---"

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function parse_yaml_value(value)
  if value == nil or value == "" then
    return nil
  end

  value = trim(value)

  if value == "true" then
    return true
  elseif value == "false" then
    return false
  elseif value:match("^%d+$") then
    return tonumber(value)
  else
    return value
  end
end

local function parse_yaml_simple(yaml_str)
  local result = {}
  local lines = vim.split(yaml_str, "\n", { plain = true })
  local current_nested_key = nil
  local current_nested = nil
  local is_array = nil

  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      goto continue
    end

    -- Array item: "  - value"
    local array_item = line:match("^%s+%-%s*(.*)$")
    if array_item and current_nested_key and is_array then
      table.insert(current_nested, trim(array_item))
      goto continue
    end

    -- Object item: "  key: value" (quoted or unquoted key)
    local obj_key, obj_value = line:match('^%s+"([^"]+)":%s*(.*)$')
    if not obj_key then
      obj_key, obj_value = line:match("^%s+([%w%.%_%-%/]+):%s*(.*)$")
    end
    if obj_key and current_nested_key and not is_array then
      current_nested[obj_key] = trim(obj_value)
      goto continue
    end

    -- Top-level key
    local key, value = line:match("^([%w%.%_%-]+):%s*(.*)$")
    if key then
      if current_nested_key then
        result[current_nested_key] = current_nested
        current_nested_key = nil
        current_nested = nil
        is_array = nil
      end

      if value == "" or value == nil then
        current_nested_key = key
        current_nested = {}
        is_array = nil -- Will be determined by first nested item
      else
        result[key] = parse_yaml_value(value)
      end
    elseif current_nested_key and is_array == nil then
      -- Determine if nested structure is array or object
      if line:match("^%s+%-") then
        is_array = true
        local item = line:match("^%s+%-%s*(.*)$")
        if item then
          table.insert(current_nested, trim(item))
        end
      elseif line:match("^%s+") then
        is_array = false
        local k, v = line:match('^%s+"([^"]+)":%s*(.*)$')
        if not k then
          k, v = line:match("^%s+([%w%.%_%-%/]+):%s*(.*)$")
        end
        if k then
          current_nested[k] = trim(v)
        end
      end
    end

    ::continue::
  end

  if current_nested_key then
    result[current_nested_key] = current_nested
  end

  return result
end

function M.parse(content)
  if not content or content == "" then
    return nil, content
  end

  local lines = vim.split(content, "\n", { plain = true })

  if #lines < 1 or trim(lines[1]) ~= FRONTMATTER_START then
    return nil, content
  end

  local end_index = nil
  for i = 2, #lines do
    if trim(lines[i]) == FRONTMATTER_END then
      end_index = i
      break
    end
  end

  if not end_index then
    return nil, content
  end

  local yaml_lines = {}
  for i = 2, end_index - 1 do
    table.insert(yaml_lines, lines[i])
  end
  local yaml_str = table.concat(yaml_lines, "\n")

  local body_lines = {}
  for i = end_index + 1, #lines do
    table.insert(body_lines, lines[i])
  end
  local body = table.concat(body_lines, "\n")

  local parsed = parse_yaml_simple(yaml_str)

  return parsed, body
end

local function serialize_value(value)
  if type(value) == "boolean" then
    return value and "true" or "false"
  elseif type(value) == "number" then
    return tostring(value)
  else
    return tostring(value)
  end
end

local function get_sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end

  local priority = {
    ["vibing.nvim"] = 1,
    session_id = 2,
    created_at = 3,
    mode = 4,
    model = 5,
    permissions_mode = 6,
    permissions_allow = 7,
    permissions_deny = 8,
    language = 9,
  }

  table.sort(keys, function(a, b)
    local pa = priority[a] or 100
    local pb = priority[b] or 100
    if pa ~= pb then
      return pa < pb
    end
    return a < b
  end)

  return keys
end

function M.serialize(data, body)
  local lines = { FRONTMATTER_START }

  local sorted_keys = get_sorted_keys(data)

  for _, key in ipairs(sorted_keys) do
    local value = data[key]
    if type(value) == "table" then
      table.insert(lines, key .. ":")
      -- Check if table is array (sequential integer keys) or object (string keys)
      local is_array = #value > 0 or next(value) == nil
      if is_array then
        for _, item in ipairs(value) do
          table.insert(lines, "  - " .. tostring(item))
        end
      else
        -- Object format with quoted keys for paths
        for k, v in pairs(value) do
          table.insert(lines, '  "' .. tostring(k) .. '": ' .. tostring(v))
        end
      end
    else
      table.insert(lines, key .. ": " .. serialize_value(value))
    end
  end

  table.insert(lines, FRONTMATTER_END)

  if body and body ~= "" then
    table.insert(lines, body)
  end

  return table.concat(lines, "\n")
end

function M.update(content, updates)
  local data, body = M.parse(content)
  if not data then
    data = {}
    body = content or ""
  end

  for k, v in pairs(updates) do
    data[k] = v
  end

  return M.serialize(data, body)
end

return M
