---@class Vibing.Application.Chat.UseCases.SearchChats
---自然文のクエリで過去のチャットを探す。
---
---`vibing-chat-search` スキルの手順を、チャットバッファを持たないエージェントのターン1回に
---任せる。スキルとの違いは、結果を本文ではなく JSON で返させてピッカーに渡すことだけ。
local M = {}

local BackgroundAgent = require("vibing.application.chat.search.background_agent")
local ChatPrompt = require("vibing.application.chat.search.chat_prompt")
local ChatAnswer = require("vibing.application.chat.search.chat_answer")

---@class Vibing.Chat.Search.Outcome
---@field results Vibing.Chat.Search.Result[]
---@field error string? 結果を得られなかった理由。設定時、results は空

---@param query string
---@param save_dir string
---@param callback fun(outcome: Vibing.Chat.Search.Outcome)
---@param on_tool fun(label: string)? エージェントがツールを呼ぶたびに呼ばれる
function M.run(query, save_dir, callback, on_tool)
  local chat_dir = vim.fn.fnamemodify(save_dir, ":p"):gsub("/$", "")
  local cwd = vim.fn.getcwd()

  BackgroundAgent.run(
    ChatPrompt.build(query, chat_dir, BackgroundAgent.language_name()),
    ChatPrompt.TOOLS,
    on_tool or function() end,
    function(text, err)
      if err then
        callback({ results = {}, error = err })
        return
      end
      local results, parse_error = ChatAnswer.parse(text, chat_dir, cwd)
      callback({ results = results or {}, error = parse_error })
    end
  )
end

return M
