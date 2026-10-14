---@class Vibing.Application.Chat.UseCases.SearchSessions
---自然文のクエリで、Claude/Codex CLI の過去のセッション（vibing.nvim の外で始めたものも）を探す。
---チャット検索と同じく、チャットバッファを持たないエージェントのターン1回に任せる。
local M = {}

local BackgroundAgent = require("vibing.application.chat.search.background_agent")
local SessionPrompt = require("vibing.application.chat.search.session_prompt")
local SessionAnswer = require("vibing.application.chat.search.session_answer")

---@class Vibing.Session.Search.Outcome
---@field results Vibing.Session.Search.Result[]
---@field error string? 結果を得られなかった理由。設定時、results は空

---@param query string
---@param callback fun(outcome: Vibing.Session.Search.Outcome)
---@param on_tool fun(label: string)? エージェントがツールを呼ぶたびに呼ばれる
function M.run(query, callback, on_tool)
  BackgroundAgent.run(
    SessionPrompt.build(query, vim.fn.getcwd(), BackgroundAgent.language_name()),
    SessionPrompt.TOOLS,
    on_tool or function() end,
    function(text, err)
      if err then
        callback({ results = {}, error = err })
        return
      end
      local results, parse_error = SessionAnswer.parse(text)
      callback({ results = results or {}, error = parse_error })
    end
  )
end

return M
