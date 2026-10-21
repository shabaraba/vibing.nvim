---@class Vibing.Testing.ChatSearchEval
---`:VibingChatSearch` の精度評価の採点。返ってきたチャットのファイル名だけを見る。
---
---1件の正誤で合否を決める `eval_harness` と違い、ここは同じクエリ集をモデルごとに回して
---再現率と適合率を比べるためのもの。実行は `tests/evals/chat_search/run.lua`。
local M = {}

---@class Vibing.ChatSearchEval.Case
---@field id string
---@field query string
---@field expected string[] 返すべきチャットのファイル名
---@field acceptable string[] 返しても誤りにしないファイル名
---@field distractors string[] 語は一致するが無関係なファイル名

---@class Vibing.ChatSearchEval.Score
---@field recall number expected のうち返した割合。expected が空なら 1
---@field precision number 返したうち expected か acceptable の割合。何も返さなければ 1
---@field exact boolean 取りこぼしも誤検出も無い
---@field missed string[]
---@field extra string[]
---@field error string?

---@param list string[]
---@return table<string, true>
local function set_of(list)
  local set = {}
  for _, item in ipairs(list) do
    set[item] = true
  end
  return set
end

---@param case Vibing.ChatSearchEval.Case
---@param returned string[] 返ってきたチャットのファイル名
---@return Vibing.ChatSearchEval.Score
function M.score(case, returned)
  local got = set_of(returned)
  local allowed = set_of(vim.list_extend(vim.deepcopy(case.expected), case.acceptable))

  local missed = vim.tbl_filter(function(name)
    return not got[name]
  end, case.expected)
  local extra = {}
  local correct = 0
  for name in pairs(got) do
    if allowed[name] then
      correct = correct + 1
    else
      extra[#extra + 1] = name
    end
  end
  table.sort(extra)

  local returned_count = vim.tbl_count(got)
  return {
    recall = #case.expected == 0 and 1 or (#case.expected - #missed) / #case.expected,
    precision = returned_count == 0 and 1 or correct / returned_count,
    exact = #missed == 0 and #extra == 0,
    missed = missed,
    extra = extra,
  }
end

---検索自体が失敗した試行。何も見つけられなかったのと区別して数えるが、点は0
---@param case Vibing.ChatSearchEval.Case
---@param error string
---@return Vibing.ChatSearchEval.Score
function M.failed(case, error)
  return { recall = 0, precision = 0, exact = false, missed = vim.deepcopy(case.expected), extra = {}, error = error }
end

---@param scores Vibing.ChatSearchEval.Score[]
---@return {recall: number, precision: number, exact: integer, errors: integer, count: integer}
function M.summarize(scores)
  local total = { recall = 0, precision = 0, exact = 0, errors = 0, count = #scores }
  for _, score in ipairs(scores) do
    total.recall = total.recall + score.recall
    total.precision = total.precision + score.precision
    total.exact = total.exact + (score.exact and 1 or 0)
    total.errors = total.errors + (score.error and 1 or 0)
  end
  if #scores > 0 then
    total.recall = total.recall / #scores
    total.precision = total.precision / #scores
  end
  return total
end

---@param case Vibing.ChatSearchEval.Case
---@param name string
---@return string
local function label(case, name)
  return vim.tbl_contains(case.distractors, name) and name .. " (distractor)" or name
end

---@param case Vibing.ChatSearchEval.Case
---@param score Vibing.ChatSearchEval.Score
---@param candidates string[]? the chats the model was shown; names the stage a miss happened at
---@return string[]
function M.format_attempt(case, score, candidates)
  if score.error then
    return { "error: " .. score.error }
  end
  local lines = {}
  for _, name in ipairs(score.missed) do
    local stage = ""
    if candidates then
      stage = vim.tbl_contains(candidates, name) and " (dropped at judgement)" or " (never a candidate)"
    end
    lines[#lines + 1] = "missed " .. name .. stage
  end
  for _, name in ipairs(score.extra) do
    lines[#lines + 1] = "extra  " .. label(case, name)
  end
  return lines
end

return M
