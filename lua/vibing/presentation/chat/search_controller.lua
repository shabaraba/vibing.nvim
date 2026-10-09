---@class Vibing.Presentation.Chat.SearchController
---`:VibingChatSearch` の入口。クエリを集め、検索の進捗を出し、結果をピッカーに渡す。
local M = {}

local notify = require("vibing.core.utils.notify")
local Progress = require("vibing.presentation.common.progress")
local SearchChats = require("vibing.application.chat.use_cases.search_chats")
local ChatSearchPicker = require("vibing.ui.chat_search_picker")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---@param query string
---@param save_dir string
local function search(query, save_dir)
  local items = {}
  for _, label in ipairs(SearchChats.STEPS) do
    items[#items + 1] = { label = label }
  end

  local progress = Progress.open({ title = "Chat Search", items = items })

  SearchChats.run(query, save_dir, function(outcome)
    progress:close()

    if outcome.degraded then
      notify.warn(
        string.format("Relevance ranking was skipped (%s); showing the raw matches", outcome.degraded),
        "ChatSearch"
      )
    end

    ChatSearchPicker.show(query, outcome.results)
  end, {
    on_step = function(index)
      progress:start(index)
    end,
    on_step_done = function(index, ok)
      progress:mark(index, ok)
    end,
  })
end

---@param opts table `nvim_create_user_command` のコマンド引数
---@param config table チャット設定（`config.chat`）
function M.handle_search_command(opts, config)
  local save_dir = FileManager.get_save_directory(config or {})
  local query = vim.trim(opts.args or "")

  if query ~= "" then
    search(query, save_dir)
    return
  end

  vim.ui.input({ prompt = "Search past chats: " }, function(input)
    local entered = vim.trim(input or "")
    if entered == "" then
      return
    end
    search(entered, save_dir)
  end)
end

return M
