---@class Vibing.Application.Chat.UseCases.SearchChats
---自然文のクエリで過去のチャットを探す。
---
---`vibing-chat-search` スキルと同じ3段構え（キーワード展開 → grep で候補を絞る → 読ませて
---関連判定と要約）を、メインモデルではなく軽量呼び出し（utility_model・ツールなし）で回す。
local M = {}

local KeywordExpander = require("vibing.application.chat.search.keyword_expander")
local CandidateFinder = require("vibing.application.chat.search.candidate_finder")
local RelevanceJudge = require("vibing.application.chat.search.relevance_judge")

---進捗表示の行。番号は `on_step` が渡す index と同じ並びで、定義はここ1箇所
M.STEPS = {
  "Expanding the query into keywords",
  "Searching the chat files",
  "Reading the candidates",
}

---@class Vibing.Chat.Search.Result
---@field entity Vibing.Domain.Chat.FileEntity
---@field summary string 関連部分の1行要約。判定に失敗したときは空
---@field hits integer

---@class Vibing.Chat.Search.Outcome
---@field results Vibing.Chat.Search.Result[]
---@field keywords string[] 実際に grep したキーワード
---@field degraded string? 判定まで届かなかった理由。設定時、results は grep の結果そのもの

---判定を諦めて grep の結果をそのまま返す。
---要約は付かないが、「見つからなかった」と言うよりは使える
---@param candidates Vibing.Chat.Search.Candidate[]
---@return Vibing.Chat.Search.Result[]
local function as_unjudged(candidates)
  local results = {}
  for _, candidate in ipairs(candidates) do
    results[#results + 1] = { entity = candidate.entity, summary = "", hits = candidate.hits }
  end
  return results
end

---@class Vibing.Chat.Search.RunOpts
---@field on_step fun(index: integer)? その段に取りかかったことを知らせる
---@field on_step_done fun(index: integer, ok: boolean)? その段の決着を知らせる

---@param opts Vibing.Chat.Search.RunOpts?
---@param name "on_step"|"on_step_done"
---@return fun(...)
local function reporter(opts, name)
  local fn = opts and opts[name]
  return function(...)
    if fn then
      fn(...)
    end
  end
end

---@param query string
---@param save_dir string
---@param callback fun(outcome: Vibing.Chat.Search.Outcome)
---@param opts Vibing.Chat.Search.RunOpts?
function M.run(query, save_dir, callback, opts)
  local step = reporter(opts, "on_step")
  local step_done = reporter(opts, "on_step_done")

  step(1)
  KeywordExpander.expand(query, function(keywords, expand_error)
    step_done(1, expand_error == nil)

    step(2)
    local candidates = CandidateFinder.find(save_dir, keywords)
    step_done(2, #candidates > 0)

    if #candidates == 0 then
      callback({ results = {}, keywords = keywords, degraded = expand_error })
      return
    end

    step(3)
    RelevanceJudge.judge(query, candidates, function(results, judge_error)
      step_done(3, judge_error == nil)

      if judge_error then
        callback({
          results = as_unjudged(candidates),
          keywords = keywords,
          degraded = judge_error,
        })
        return
      end

      callback({ results = results, keywords = keywords, degraded = expand_error })
    end)
  end)
end

return M
