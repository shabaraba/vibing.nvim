---@class Vibing.Application.Chat.Search.CandidateFinder
---キーワード群でチャットファイルを絞り込み、判定に渡す抜粋を組み立てる。
---
---`## User` に限らずファイル全体を見る。ユーザーの当時の言い回しが曖昧でも、同じ話題が
---アシスタントの返答側にはっきり書かれていることが多い。
local M = {}

local ChatRepository = require("vibing.infrastructure.storage.chat_repository")

---抜粋に付ける前後の行数
local CONTEXT_LINES = 2
---1ファイルあたりの抜粋行数の上限。判定呼び出しは候補をまとめて1回なので、ここが伸びると
---コンテキストを食い潰す
local MAX_EXCERPT_LINES = 40
---判定に回す候補数の上限。超えた分はヒット数の多い順に切る
local MAX_CANDIDATES = 12

---@class Vibing.Chat.Search.Candidate
---@field entity Vibing.Domain.Chat.FileEntity
---@field hits integer マッチした行数
---@field excerpt string[] 前後の文脈を含む抜粋

---@param keywords string[]
---@return string[] 小文字化・空要素を除いた検索語
function M.needles(keywords)
  local needles = {}
  local seen = {}

  for _, keyword in ipairs(keywords or {}) do
    local lowered = vim.trim(keyword):lower()
    if lowered ~= "" and not seen[lowered] then
      seen[lowered] = true
      needles[#needles + 1] = lowered
    end
  end

  return needles
end

---@param line string
---@param needles string[]
---@return boolean
local function line_matches(line, needles)
  local lowered = line:lower()
  for _, needle in ipairs(needles) do
    if lowered:find(needle, 1, true) then
      return true
    end
  end
  return false
end

---マッチ行の前後を集めて抜粋にする。重なった範囲は二重に入れない
---@param lines string[]
---@param matched integer[]
---@return string[]
local function build_excerpt(lines, matched)
  local excerpt = {}
  local last_taken = 0

  for _, index in ipairs(matched) do
    local from = math.max(last_taken + 1, index - CONTEXT_LINES)
    local to = math.min(#lines, index + CONTEXT_LINES)

    if from > last_taken + 1 then
      excerpt[#excerpt + 1] = "..."
    end

    for i = from, to do
      excerpt[#excerpt + 1] = lines[i]
      if #excerpt >= MAX_EXCERPT_LINES then
        return excerpt
      end
    end

    last_taken = to
  end

  return excerpt
end

---@param entity Vibing.Domain.Chat.FileEntity
---@param needles string[]
---@return Vibing.Chat.Search.Candidate?
function M.scan(entity, needles)
  local ok, lines = pcall(vim.fn.readfile, entity.path)
  if not ok or type(lines) ~= "table" then
    return nil
  end

  local matched = {}
  for index, line in ipairs(lines) do
    if line_matches(line, needles) then
      matched[#matched + 1] = index
    end
  end

  if #matched == 0 then
    return nil
  end

  return {
    entity = entity,
    hits = #matched,
    excerpt = build_excerpt(lines, matched),
  }
end

---@param save_dir string
---@param keywords string[]
---@param opts {max_candidates: integer?}?
---@return Vibing.Chat.Search.Candidate[]
function M.find(save_dir, keywords, opts)
  local needles = M.needles(keywords)
  if #needles == 0 then
    return {}
  end

  local candidates = {}
  for _, entity in ipairs(ChatRepository.find_all(save_dir)) do
    local candidate = M.scan(entity, needles)
    if candidate then
      candidates[#candidates + 1] = candidate
    end
  end

  table.sort(candidates, function(a, b)
    if a.hits ~= b.hits then
      return a.hits > b.hits
    end
    return (a.entity.created_at or 0) > (b.entity.created_at or 0)
  end)

  local limit = (opts and opts.max_candidates) or MAX_CANDIDATES
  if #candidates > limit then
    candidates = vim.list_slice(candidates, 1, limit)
  end

  return candidates
end

return M
