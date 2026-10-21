---@class Vibing.Application.Chat.Search.QueryTerms
---`:VibingChatSearch` の1段目。クエリを、チャットの本文に字面どおり現れそうな語の集まりに
---言い換えさせる。検索そのものは `chat_grep.lua` が行うので、モデルは語を挙げるだけでよい。
---
---語は「概念」ごとにまとめさせる。1つの概念の言い換えが何語当たっても1回と数え、別の概念に
---当たったチャットほど上に来るようにするため。
local M = {}

local MAX_CONCEPTS = 5
local MAX_TERMS_PER_CONCEPT = 10

M.SCHEMA = {
  type = "object",
  properties = {
    concepts = {
      type = "array",
      items = {
        type = "object",
        properties = { terms = { type = "array", items = { type = "string" } } },
        required = { "terms" },
        additionalProperties = false,
      },
    },
  },
  required = { "concepts" },
  additionalProperties = false,
}

---語を挙げるだけなら思考は要らない。Haiku で 8〜26 秒が 4 秒前後になり、取りこぼしも増えなかった。
---判定（`chat_judgement.lua`）は思考を外すと取りこぼしと混入が増えたので、こちらだけに付ける
M.ADAPTER_OPTS = { thinking = false }

---@param query string
---@param context string[] クエリから引けた補足（PR のタイトル等）
---@return string
function M.build(query, context)
  local lines = {
    "Find the past conversations with a coding assistant that are about the query below. This step",
    "only lists the search terms a plain substring search should look for in the conversation logs.",
    "",
    "Query: " .. query,
  }
  for _, line in ipairs(context) do
    lines[#lines + 1] = "Context: " .. line
  end
  vim.list_extend(lines, {
    "",
    "Split the query into its 1-4 distinct concepts. For each concept give 4-10 short terms that",
    "would appear literally in a conversation about it: the words of the query itself, Japanese",
    "and English renderings, synonyms, the technical names an engineer would use for it, and",
    "likely identifiers (library, function, column or file names, in the casing they are written).",
    "The conversation often names the topic only in the engineer's answer, in different words from",
    "the query, so think about how the fix or the cause would be described, not only the symptom.",
    "Keep each term to one to three words. Leave out words that would appear in almost any",
    "conversation about a software project, such as task, bug, fix, code, chat or 問題.",
    "",
    'Answer with JSON: {"concepts": [{"terms": ["...", "..."]}]}',
  })
  return table.concat(lines, "\n")
end

---@param decoded table?
---@return string[][]? concepts
---@return string? error
function M.parse(decoded)
  if type(decoded) ~= "table" or type(decoded.concepts) ~= "table" then
    return nil, "the search agent returned no search terms"
  end
  local concepts = {}
  for _, concept in ipairs(decoded.concepts) do
    local terms, seen = {}, {}
    for _, term in ipairs(type(concept) == "table" and type(concept.terms) == "table" and concept.terms or {}) do
      term = type(term) == "string" and vim.trim(term) or ""
      local key = term:lower()
      if term ~= "" and not seen[key] and #terms < MAX_TERMS_PER_CONCEPT then
        seen[key] = true
        terms[#terms + 1] = term
      end
    end
    if #terms > 0 and #concepts < MAX_CONCEPTS then
      concepts[#concepts + 1] = terms
    end
  end
  if #concepts == 0 then
    return nil, "the search agent returned no search terms"
  end
  return concepts, nil
end

return M
