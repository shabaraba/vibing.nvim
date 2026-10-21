---@class Vibing.Application.Chat.Search.JsonAnswer
---裏のエージェントの答えの末尾にある JSON を読む。構造化出力を持たないバックエンド用。
local M = {}

local function close_containers(block)
  local stack, quoted, escaped = {}, false, false
  for index = 1, #block do
    local char = block:sub(index, index)
    if quoted then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      quoted = true
    elseif char == "{" or char == "[" then
      stack[#stack + 1] = char == "{" and "}" or "]"
    elseif char == "}" or char == "]" then
      if stack[#stack] ~= char then
        return nil
      end
      stack[#stack] = nil
    end
  end
  if quoted or #stack == 0 then
    return nil
  end
  local suffix = {}
  for index = #stack, 1, -1 do
    suffix[#suffix + 1] = stack[index]
  end
  return block .. table.concat(suffix)
end

---応答の末尾の JSON ブロックを読む。本文の途中にも例が出うるので、最後のブロックを採る
---@param text string?
---@return table? decoded
---@return string? error
function M.last(text)
  local block
  for found in (text or ""):gmatch("```json%s*\n(.-)\n%s*```") do
    block = found
  end
  block = block or (text or ""):match("(%b{})%s*$")
  if not block then
    return nil, "the search agent returned no JSON result"
  end

  local ok, decoded = pcall(vim.json.decode, block)
  if not ok then
    local closed = close_containers(block)
    if closed then
      ok, decoded = pcall(vim.json.decode, closed)
    end
  end
  if not ok or type(decoded) ~= "table" then
    return nil, "the search agent returned a malformed result"
  end
  return decoded, nil
end

return M
