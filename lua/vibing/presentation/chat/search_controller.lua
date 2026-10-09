---@class Vibing.Presentation.Chat.SearchController
---`:VibingChatSearch` と `:VibingSessionSearch` の入口。クエリを集め、検索の進捗を出し、結果を
---ピッカーに渡す。どちらも裏のエージェントのターン1回なので、ここの形は同じ。
local M = {}

local notify = require("vibing.core.utils.notify")
local Progress = require("vibing.presentation.common.progress")

---進捗の1行。エージェントが何をしているかは、この行をツール呼び出しで書き換えて見せる
local SEARCHING = "Searching"

---@class Vibing.Search.Spec
---@field title string 進捗の枠と通知に出す名前
---@field prompt string クエリを尋ねるときの文言
---@field run fun(query: string, callback: fun(outcome: {results: table[], error: string?}), on_tool: fun(label: string))
---@field show fun(query: string, results: table[])

---@param spec Vibing.Search.Spec
---@param query string
local function search(spec, query)
  local progress = Progress.open({ title = spec.title, items = { { label = SEARCHING } } })
  progress:start(1)

  spec.run(query, function(outcome)
    progress:mark(1, outcome.error == nil)
    progress:close()

    if outcome.error then
      notify.error(string.format("%s failed: %s", spec.title, outcome.error), spec.title)
      return
    end

    spec.show(query, outcome.results)
  end, function(label)
    progress:relabel(1, label)
  end)
end

---@param spec Vibing.Search.Spec
---@param args string? コマンドの引数
local function prompt_and_search(spec, args)
  local query = vim.trim(args or "")
  if query ~= "" then
    search(spec, query)
    return
  end

  vim.ui.input({ prompt = spec.prompt }, function(input)
    local entered = vim.trim(input or "")
    if entered ~= "" then
      search(spec, entered)
    end
  end)
end

---@param opts table `nvim_create_user_command` のコマンド引数
---@param config table チャット設定（`config.chat`）
function M.handle_search_command(opts, config)
  local save_dir = require("vibing.presentation.chat.modules.file_manager").get_save_directory(config or {})
  local SearchChats = require("vibing.application.chat.use_cases.search_chats")

  prompt_and_search({
    title = "Chat Search",
    prompt = "Search past chats: ",
    run = function(query, callback, on_tool)
      SearchChats.run(query, save_dir, callback, on_tool)
    end,
    show = require("vibing.ui.chat_search_picker").show,
  }, opts.args)
end

---@param opts table `nvim_create_user_command` のコマンド引数
function M.handle_session_search_command(opts)
  prompt_and_search({
    title = "Session Search",
    prompt = "Search past CLI sessions: ",
    run = require("vibing.application.chat.use_cases.search_sessions").run,
    show = require("vibing.ui.session_search_picker").show,
  }, opts.args)
end

return M
