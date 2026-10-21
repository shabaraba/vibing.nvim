---@class Vibing.Application.Chat.Search.ChatGrep
---`:VibingChatSearch` の2段目。挙がった語でチャットのディレクトリを `rg` し、点数順に候補を残す。
---
---モデルにシェルを渡さずにここで検索するのは、`cd dir; rg ...` や `rg ... | head` のような
---複合コマンドが `Bash(rg:*)` に一致せず拒否され、検索が1度も通らないターンが多かったため。
local M = {}

M.MAX_CANDIDATES = 15

---@class Vibing.Chat.Search.Candidate
---@field path string
---@field score number
---@field terms string[] このチャットに当たった語

---どの語がどのチャットに何行当たったかから、候補を点数順に並べる。
---
---語の重みは当たったチャットの少なさ（IDF）で、ほぼ全部に当たる語は0になる。1つの概念は
---その中で一番効いた語だけを数えるので、言い換えを並べた概念ほど有利になることはない。
---@param hits table<string, table<string, integer>> 語 → パス → 当たった行数
---@param concepts string[][]
---@param total integer ディレクトリのチャット数
---@return Vibing.Chat.Search.Candidate[]
function M.rank(hits, concepts, total)
  local scores, terms_of = {}, {}
  for _, concept in ipairs(concepts) do
    local best = {}
    for _, term in ipairs(concept) do
      local per_file = hits[term] or {}
      local weight = math.max(0, math.log((total + 0.5) / (vim.tbl_count(per_file) + 0.5)))
      for path, count in pairs(per_file) do
        best[path] = math.max(best[path] or 0, weight * math.log(1 + count))
        terms_of[path] = terms_of[path] or {}
        terms_of[path][#terms_of[path] + 1] = term
      end
    end
    for path, value in pairs(best) do
      scores[path] = (scores[path] or 0) + value
    end
  end

  local candidates = {}
  for path, score in pairs(scores) do
    if score > 0 then
      candidates[#candidates + 1] = { path = path, score = score, terms = terms_of[path] }
    end
  end
  table.sort(candidates, function(a, b)
    return a.score == b.score and a.path > b.path or a.score > b.score
  end)
  return vim.list_slice(candidates, 1, M.MAX_CANDIDATES)
end

---`rg -c` の出力（`<path>:<count>` の行）を読む
---@param stdout string?
---@return table<string, integer>
function M.parse_counts(stdout)
  local counts = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local path, count = line:match("^(.*):(%d+)$")
    if path then
      counts[path] = tonumber(count)
    end
  end
  return counts
end

---@param dir string
---@param concepts string[][]
---@param callback fun(candidates: Vibing.Chat.Search.Candidate[]?, error: string?)
function M.run(dir, concepts, callback)
  if vim.fn.executable("rg") ~= 1 then
    callback(nil, "ripgrep (rg) is required to search chats")
    return
  end

  local terms = vim.fn.uniq(vim.fn.sort(vim.iter(concepts):flatten():totable()))
  local total = #vim.fn.globpath(dir, "*.md", false, true)
  local hits, pending, failure = {}, #terms, nil

  for _, term in ipairs(terms) do
    -- `.vibing/` is usually git-ignored, so `--no-ignore`; `-F` keeps `.`, `(` and `+` literal
    local cmd = { "rg", "--no-ignore", "--hidden", "-F", "-i", "-c", "--glob", "*.md", "--", term, dir }
    vim.system(cmd, { text = true }, function(result)
      if result.code == 0 or result.code == 1 then
        hits[term] = M.parse_counts(result.stdout)
      else
        failure = failure or vim.trim(result.stderr or "rg failed")
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          if failure then
            callback(nil, failure)
          else
            callback(M.rank(hits, concepts, total), nil)
          end
        end)
      end
    end)
  end
end

return M
