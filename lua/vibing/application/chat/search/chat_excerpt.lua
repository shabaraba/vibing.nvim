---@class Vibing.Application.Chat.Search.ChatExcerpt
---`:VibingChatSearch` の3段目の材料。候補のチャットから、判定に要る部分だけを切り出す。
---
---チャットは平均数十KBあり、全文を読ませると判定がそれに引きずられる。何の話かを示す1行と、
---語が当たった箇所の前後だけを渡す。
local M = {}

M.MAX_CHARS = 1200
local CONTEXT_LINES = 2
local MAX_LINE_CHARS = 200

---@class Vibing.Chat.Search.Excerpt
---@field date string
---@field title string
---@field text string

---@param line string
---@return string
local function clip(line)
  line = vim.trim(line)
  if vim.fn.strchars(line) > MAX_LINE_CHARS then
    return vim.fn.strcharpart(line, 0, MAX_LINE_CHARS - 1) .. "…"
  end
  return line
end

---要約があればその一行要約、無ければ最初のユーザー発言の1行目
---@param lines string[]
---@return string
local function title_of(lines)
  local after_summary, after_user = false, false
  for _, line in ipairs(lines) do
    if line:match("^### .*一行要約") then
      after_summary = true
    elseif after_summary and vim.trim(line) ~= "" then
      return clip(line)
    elseif line:match("^## User") then
      after_user = true
    elseif after_user and vim.trim(line) ~= "" and not line:match("^#") then
      return clip(line)
    end
  end
  return ""
end

---@param lines string[]
---@param path string
---@return string
local function date_of(lines, path)
  for _, line in ipairs(lines) do
    local date = line:match("^created_at:%s*(%d%d%d%d%-%d%d%-%d%d)")
    if date then
      return date
    end
  end
  local y, m, d = vim.fn.fnamemodify(path, ":t"):match("(%d%d%d%d)(%d%d)(%d%d)")
  return y and string.format("%s-%s-%s", y, m, d) or ""
end

---@param lines string[]
---@param terms string[]
---@return string
local function windows_of(lines, terms)
  local lowered = vim.tbl_map(string.lower, terms)
  local matches = {}
  for index, line in ipairs(lines) do
    local text, distinct = line:lower(), 0
    for _, term in ipairs(lowered) do
      if text:find(term, 1, true) then
        distinct = distinct + 1
      end
    end
    if distinct > 0 then
      matches[#matches + 1] = { index = index, distinct = distinct }
    end
  end
  table.sort(matches, function(a, b)
    return a.distinct == b.distinct and a.index < b.index or a.distinct > b.distinct
  end)

  local taken, used = {}, 0
  for _, match in ipairs(matches) do
    local first, last = math.max(1, match.index - CONTEXT_LINES), math.min(#lines, match.index + CONTEXT_LINES)
    local chunk = {}
    for index = first, last do
      if not taken[index] and vim.trim(lines[index]) ~= "" then
        chunk[#chunk + 1] = index
      end
    end
    local size = 0
    for _, index in ipairs(chunk) do
      size = size + #clip(lines[index]) + 1
    end
    if used + size > M.MAX_CHARS then
      break
    end
    for _, index in ipairs(chunk) do
      taken[index] = true
    end
    used = used + size
  end

  local out, previous = {}, nil
  for index = 1, #lines do
    if taken[index] then
      if previous and index > previous + 1 then
        out[#out + 1] = "…"
      end
      out[#out + 1] = clip(lines[index])
      previous = index
    end
  end
  return table.concat(out, "\n")
end

---@param path string
---@param terms string[]
---@return Vibing.Chat.Search.Excerpt
function M.build(path, terms)
  local ok, lines = pcall(vim.fn.readfile, path)
  lines = ok and lines or {}
  return { date = date_of(lines, path), title = title_of(lines), text = windows_of(lines, terms) }
end

return M
