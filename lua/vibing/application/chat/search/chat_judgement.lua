---@class Vibing.Application.Chat.Search.ChatJudgement
---`:VibingChatSearch` の3段目。候補の抜粋を見せ、クエリについてのチャットだけを選ばせる。
---
---候補は `C1` のような番号で示し、答えも番号で受け取る。パスを書き写させると、長いファイル名の
---写し間違いがそのまま取りこぼしになるため。
local M = {}

local FileEntity = require("vibing.domain.chat.file_entity")

---@class Vibing.Chat.Search.Result
---@field entity Vibing.Domain.Chat.FileEntity
---@field summary string
---@field group string 検索語との関係で分けた分類名
local one_line = require("vibing.application.chat.search.background_agent").one_line

local string_value = { type = "string" }
local function object(properties, required)
  return { type = "object", properties = properties, required = required, additionalProperties = false }
end
local chat = object({ id = string_value, summary = string_value }, { "id", "summary" })
local group = object({ label = string_value, chats = { type = "array", items = chat } }, { "label", "chats" })
M.SCHEMA = object({ groups = { type = "array", items = group } }, { "groups" })

---@param index integer
---@return string
local function id_of(index)
  return "C" .. index
end

---@param query string
---@param excerpts Vibing.Chat.Search.Excerpt[] 候補と同じ順
---@param language_line string
---@return string
function M.build(query, excerpts, language_line)
  local lines = {
    "Find the past conversations with a coding assistant that are about the query below. Excerpts",
    "of the candidates a keyword search found follow; decide which of them are about the query.",
    "",
    "Query: " .. query,
    "",
  }
  for index, excerpt in ipairs(excerpts) do
    vim.list_extend(lines, {
      string.format("### %s (%s) %s", id_of(index), excerpt.date, excerpt.title),
      excerpt.text,
      "",
    })
  end
  vim.list_extend(lines, {
    "Keep a conversation only if the query's topic is what it works on, or a substantial part of",
    "it: the task itself, a follow-up on it, or an earlier investigation of the same problem. The",
    "keywords were chosen loosely, so most candidates only mention a word in passing; drop those.",
    "The query may name the topic differently from the conversation, for example by its symptom",
    "while the conversation names its cause. An empty result is a valid answer.",
    "",
    "Group the kept conversations by how they relate to the query (for example: handled it",
    "directly, followed up on it), using as few groups as fit, most relevant first. Give each a",
    "1-2 line summary of the relevant part.",
    language_line,
    "",
    'Answer with JSON: {"groups": [{"label": "<group>", "chats": [{"id": "C1", "summary": "..."}]}]}',
  })
  return table.concat(lines, "\n")
end

---@param decoded table?
---@param candidates Vibing.Chat.Search.Candidate[] 抜粋と同じ順
---@return Vibing.Chat.Search.Result[]? results
---@return string? error
function M.parse(decoded, candidates)
  if type(decoded) ~= "table" or type(decoded.groups) ~= "table" then
    return nil, "the search agent returned a malformed result"
  end
  local by_id = {}
  for index, candidate in ipairs(candidates) do
    by_id[id_of(index)] = candidate
  end

  local results, seen = {}, {}
  for _, entry in ipairs(decoded.groups) do
    local label = type(entry) == "table" and one_line(entry.label) or ""
    for _, picked in ipairs(type(entry) == "table" and type(entry.chats) == "table" and entry.chats or {}) do
      local id = type(picked) == "table" and type(picked.id) == "string" and vim.trim(picked.id):upper()
      local candidate = id and not seen[id] and by_id[id]
      local entity = candidate and FileEntity.new(candidate.path)
      if entity then
        seen[id] = true
        results[#results + 1] = { entity = entity, summary = one_line(picked.summary), group = label }
      end
    end
  end
  return results, nil
end

return M
