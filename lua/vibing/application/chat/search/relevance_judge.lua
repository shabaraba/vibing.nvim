---@class Vibing.Application.Chat.Search.RelevanceJudge
---grep を通った候補を実際に読ませ、クエリの話題かどうかを判定して1行要約を付ける。
---
---キーワードが1度出てくるだけのファイルは「その話をしたチャット」ではない。ここが無いと
---検索結果は素の grep に戻る。候補はまとめて1回の軽量呼び出しに乗せる（1ファイル1回だと
---CLI の起動コストが候補数ぶん掛かる）。
local M = {}

local Llm = require("vibing.application.chat.search.llm")

---@class Vibing.Chat.Search.Verdict
---@field relevant boolean
---@field summary string

local OUTPUT_RULES = {
  "Answer with one line per excerpt and nothing else, in this exact format:",
  "<number>|YES|<summary>",
  "<number>|NO|",
  "",
  "Rules:",
  "- YES only when the conversation is actually ABOUT the query. A keyword that appears in",
  "  passing, in a file listing or in an unrelated aside is NO.",
  "- The summary names what was discussed or decided about the query, on ONE line.",
  "- Emit a line for every number, including the ones you answer NO.",
}

---@param query string
---@param candidates Vibing.Chat.Search.Candidate[]
---@return string
function M.build_prompt(query, candidates)
  local lines = {
    "Search query: " .. query,
    "",
    "Below are excerpts from past conversations between a user and an AI coding assistant.",
    "",
  }

  for index, candidate in ipairs(candidates) do
    lines[#lines + 1] = string.format(
      "[%d] %s (%s)",
      index,
      candidate.entity:get_display_name(),
      candidate.entity:get_formatted_date()
    )
    vim.list_extend(lines, candidate.excerpt)
    lines[#lines + 1] = ""
  end

  vim.list_extend(lines, OUTPUT_RULES)

  local lang_name = Llm.language_name()
  if lang_name then
    lines[#lines + 1] = "- Write the summary in " .. lang_name .. "."
  end

  return table.concat(lines, "\n")
end

---@param text string?
---@return table<integer, Vibing.Chat.Search.Verdict>
function M.parse(text)
  local verdicts = {}

  for _, line in ipairs(Llm.meaningful_lines(text)) do
    local index, decision, summary = line:match("^%[?(%d+)%]?%s*|%s*(%a+)%s*|?%s*(.*)$")
    if index then
      verdicts[tonumber(index)] = {
        relevant = decision:upper() == "YES",
        summary = vim.trim(summary or ""),
      }
    end
  end

  return verdicts
end

---判定を候補に当て、関連ありだけを新しい順に返す。
---判定行が無かった候補は落とす（モデルが触れなかったものを「関連あり」とみなすと、
---grep のノイズがそのまま結果になる）
---@param candidates Vibing.Chat.Search.Candidate[]
---@param verdicts table<integer, Vibing.Chat.Search.Verdict>
---@return Vibing.Chat.Search.Result[]
function M.apply(candidates, verdicts)
  local results = {}

  for index, candidate in ipairs(candidates) do
    local verdict = verdicts[index]
    if verdict and verdict.relevant then
      results[#results + 1] = {
        entity = candidate.entity,
        summary = verdict.summary,
        hits = candidate.hits,
      }
    end
  end

  table.sort(results, function(a, b)
    return (a.entity.created_at or 0) > (b.entity.created_at or 0)
  end)

  return results
end

---@param query string
---@param candidates Vibing.Chat.Search.Candidate[]
---@param callback fun(results: Vibing.Chat.Search.Result[], error: string?)
function M.judge(query, candidates, callback)
  if #candidates == 0 then
    callback({}, nil)
    return
  end

  Llm.request(M.build_prompt(query, candidates), function(text, err)
    if err then
      callback({}, err)
      return
    end

    callback(M.apply(candidates, M.parse(text)), nil)
  end)
end

return M
