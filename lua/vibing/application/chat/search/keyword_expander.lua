---@class Vibing.Application.Chat.Search.KeywordExpander
---自然文のクエリを、過去チャットに実際に現れる語へ展開する。
---
---チャットの中身は日本語と英語が混ざった自由文で、ユーザーの言い回しと当時書いた語はしばしば
---違う（「webfetchのURL表示」で書かれているのは `WebFetch` や「閲覧したurl」）。クエリをそのまま
---grep すると、その食い違いの分だけ黙って取りこぼす。
local M = {}

local Llm = require("vibing.application.chat.search.llm")

local MAX_KEYWORDS = 4

local RULES = {
  "List 2-4 search keywords that would appear VERBATIM in those conversations.",
  "",
  "Rules:",
  "- Keep the literal terms from the query, including identifiers, file names and English product names.",
  "- Add the obvious rephrasings: the same topic in the other language, and common synonyms.",
  "- Each keyword is a single word or a short phrase, never a sentence.",
  "- One keyword per line. No numbering, no bullets, no quotes, no explanation.",
}

---@param query string
---@return string
local function build_prompt(query)
  local lines = {
    query,
    "",
    "The line above is a search query for past conversations between a user and an AI coding assistant.",
    "",
  }
  vim.list_extend(lines, RULES)
  return table.concat(lines, "\n")
end

---箇条書き・番号・引用符が付いて返ってきても語だけを取り出す
---@param line string
---@return string
local function strip_decoration(line)
  local text = line:gsub("^[%-%*%+]%s+", ""):gsub("^%d+[%.%)]%s+", "")
  text = text:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  return vim.trim(text)
end

---@param text string?
---@return string[]
function M.parse(text)
  local keywords = {}
  local seen = {}

  for _, line in ipairs(Llm.meaningful_lines(text)) do
    local keyword = strip_decoration(line)
    local key = keyword:lower()
    if keyword ~= "" and not seen[key] then
      seen[key] = true
      keywords[#keywords + 1] = keyword
      if #keywords >= MAX_KEYWORDS then
        break
      end
    end
  end

  return keywords
end

---クエリをキーワード群に展開する。
---展開に失敗したときはクエリ自身を唯一のキーワードとして返す。検索が何も返さないより、
---素朴な grep に落ちたほうが使える
---@param query string
---@param callback fun(keywords: string[], error: string?)
function M.expand(query, callback)
  Llm.request(build_prompt(query), function(text, err)
    if err then
      callback({ query }, err)
      return
    end

    local keywords = M.parse(text)
    if #keywords == 0 then
      callback({ query }, nil)
      return
    end

    callback(keywords, nil)
  end)
end

return M
