---@class Vibing.Application.Chat.UseCases.SearchChats
---自然文のクエリで過去のチャットを探す。
---
---モデルに任せるのは言葉の仕事2つだけで、どちらも道具を持たない軽量呼び出し:
---  1. クエリを検索語に言い換える（`query_terms.lua`）
---  2. 抜粋を読んでクエリについてのチャットを選ぶ（`chat_judgement.lua`）
---その間の検索・順位付け・抜粋作りは Lua が行う（`chat_grep.lua` / `chat_excerpt.lua`）。
---以前は1ターンのエージェントに `rg` を打たせていたが、複合コマンドが許可に一致せず検索が
---1度も通らないターンが多く、小さいモデルほどそれで取りこぼした。
local M = {}

local BackgroundAgent = require("vibing.application.chat.search.background_agent")
local ChatExcerpt = require("vibing.application.chat.search.chat_excerpt")
local ChatGrep = require("vibing.application.chat.search.chat_grep")
local ChatJudgement = require("vibing.application.chat.search.chat_judgement")
local GithubReference = require("vibing.application.chat.search.github_reference")
local QueryTerms = require("vibing.application.chat.search.query_terms")

---@class Vibing.Chat.Search.Outcome
---@field results Vibing.Chat.Search.Result[]
---@field error string? 結果を得られなかった理由。設定時、results は空

local decode = BackgroundAgent.last_json

---@param query string
---@param candidates Vibing.Chat.Search.Candidate[]
---@param callback fun(outcome: Vibing.Chat.Search.Outcome)
---@param on_tool fun(label: string)
local function judge(query, candidates, callback, on_tool)
  if #candidates == 0 then
    callback({ results = {} })
    return
  end
  on_tool(string.format("Reading %d chats", #candidates))
  local excerpts = vim.tbl_map(function(candidate)
    return ChatExcerpt.build(candidate.path, candidate.terms)
  end, candidates)
  local prompt = ChatJudgement.build(query, excerpts, BackgroundAgent.language_line(BackgroundAgent.language_name()))

  BackgroundAgent.run(prompt, nil, on_tool, function(text, err)
    local decoded, decode_error = decode(text)
    local results, parse_error = ChatJudgement.parse(decoded, candidates)
    local failure = err or decode_error or parse_error
    callback({ results = failure and {} or results, error = failure })
  end, ChatJudgement.SCHEMA)
end

---@param query string
---@param save_dir string `ChatDirectory.resolve()` が返した検索先
---@param callback fun(outcome: Vibing.Chat.Search.Outcome)
---@param on_tool fun(label: string)? 段階が進むたびに呼ばれる（進捗表示用）
function M.run(query, save_dir, callback, on_tool)
  on_tool = on_tool or function() end
  local chat_dir = vim.fn.fnamemodify(save_dir, ":p"):gsub("/$", "")

  GithubReference.resolve(query, vim.fn.getcwd(), function(reference)
    on_tool("Choosing search terms")
    BackgroundAgent.run(QueryTerms.build(query, reference.context), nil, on_tool, function(text, err)
      local decoded, decode_error = decode(text)
      local concepts, terms_error = QueryTerms.parse(decoded)
      if err or not concepts then
        callback({ results = {}, error = err or decode_error or terms_error })
        return
      end
      if #reference.terms > 0 then
        concepts[#concepts + 1] = reference.terms
      end

      on_tool(string.format("Searching %d terms", #vim.iter(concepts):flatten():totable()))
      ChatGrep.run(chat_dir, concepts, function(candidates, grep_error)
        if grep_error then
          callback({ results = {}, error = grep_error })
          return
        end
        judge(query, candidates, callback, on_tool)
      end)
    end, QueryTerms.SCHEMA, QueryTerms.ADAPTER_OPTS)
  end)
end

return M
