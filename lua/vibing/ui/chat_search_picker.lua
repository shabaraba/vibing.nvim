---@class Vibing.UI.ChatSearchPicker
---チャット検索の結果を、日付・タイトル・要約の一覧として出すピッカー。
---
---Telescope があればプレビュー付きのフロートで `<Tab>` の複数選択が使える。無い環境では
---`vim.ui.select` に落ちるので1件ずつになる（`chat_deletion_picker` と同じ構え）。
local M = {}

local notify = require("vibing.core.utils.notify")
local ChatOpener = require("vibing.presentation.chat.modules.chat_opener")

---要約が空（判定まで届かなかった）ときに代わりに出す文言
local NO_SUMMARY = "(no summary)"

---@param result Vibing.Chat.Search.Result
---@return string
local function summary_of(result)
  return result.summary ~= "" and result.summary or NO_SUMMARY
end

---@param results Vibing.Chat.Search.Result[]
local function open_results(results)
  if #results == 0 then
    notify.warn("No chat selected")
    return
  end

  local paths = vim.tbl_map(function(result)
    return result.entity.path
  end, results)

  local opened = ChatOpener.open_all(paths)
  if opened > 1 then
    notify.info(string.format("Opened %d chats (%d in the background)", opened, opened - 1))
  end
end

---@param query string
---@param results Vibing.Chat.Search.Result[]
function M.show(query, results)
  if #results == 0 then
    notify.info(string.format("No past chat matched: %s", query))
    return
  end

  if pcall(require, "telescope") then
    M._show_telescope(query, results)
  else
    M._show_native(query, results)
  end
end

---@param query string
---@param results Vibing.Chat.Search.Result[]
function M._show_telescope(query, results)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 19 }, -- 日時
      { width = 36 }, -- タイトル
      { remaining = true }, -- 要約
    },
  })

  pickers
    .new({}, {
      prompt_title = string.format("Chat Search: %s (<Tab> to select, <CR> to open)", query),
      finder = finders.new_table({
        results = results,
        entry_maker = function(result)
          local entity = result.entity
          return {
            value = result,
            path = entity.path,
            ordinal = entity:get_display_name() .. " " .. result.summary,
            display = function(entry)
              return displayer({
                { entry.value.entity:get_formatted_date(), "TelescopeResultsNumber" },
                { entry.value.entity:get_display_name(), "TelescopeResultsIdentifier" },
                { summary_of(entry.value), "TelescopeResultsString" },
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = conf.file_previewer({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selections = picker:get_multi_selection()

          if #selections == 0 then
            local current = action_state.get_selected_entry()
            selections = current and { current } or {}
          end

          actions.close(prompt_bufnr)

          open_results(vim.tbl_map(function(entry)
            return entry.value
          end, selections))
        end)
        return true
      end,
    })
    :find()
end

---@param query string
---@param results Vibing.Chat.Search.Result[]
function M._show_native(query, results)
  vim.ui.select(results, {
    prompt = string.format("Chats matching: %s", query),
    format_item = function(result)
      return string.format(
        "%s  %s - %s",
        result.entity:get_formatted_date(),
        result.entity:get_display_name(),
        summary_of(result)
      )
    end,
  }, function(choice)
    if choice then
      open_results({ choice })
    end
  end)
end

return M
