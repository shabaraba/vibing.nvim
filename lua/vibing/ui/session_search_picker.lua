---@class Vibing.UI.SessionSearchPicker
---セッション検索の結果を、分類・日時・CLI・題名の一覧として出すピッカー。
---並びはエージェントが返した分類の順（関連の強い分類が先）のまま。
---
---`<CR>` は元のセッションを resume するチャット、`<C-h>` は要約から続ける引き継ぎのチャットを開く。
---Telescope が無い環境では `vim.ui.select` で選んでから、どちらで開くかをもう一度選ぶ。
local M = {}

local notify = require("vibing.core.utils.notify")
local SessionOpener = require("vibing.presentation.chat.modules.session_opener")
local SessionAnswer = require("vibing.application.chat.search.session_answer")

---@param result Vibing.Session.Search.Result
---@return string
local function title_of(result)
  return result.title ~= "" and result.title or result.session_id
end

---プレビュー欄の中身。JSONL の生データは読めたものではないので、エージェントの要約と識別子を出す
---@param result Vibing.Session.Search.Result
---@return string[]
function M.preview_lines(result)
  local _, reason = SessionOpener.resume_target(result)
  local lines = {
    "# " .. title_of(result),
    "",
  }
  vim.list_extend(lines, vim.split(result.summary ~= "" and result.summary or "(no summary)", "\n"))
  vim.list_extend(lines, {
    "",
    "- backend: " .. result.backend,
    "- session_id: " .. result.session_id,
    "- cwd: " .. (result.cwd or "(unknown)"),
    "- updated: " .. SessionAnswer.short_date(result.updated_at),
    "",
    reason and ("<CR> cannot resume: " .. reason) or "<CR> resume this session",
    "<C-h> hand it off to a new chat",
  })
  return lines
end

---@param query string
---@param results Vibing.Session.Search.Result[]
function M.show(query, results)
  if #results == 0 then
    notify.info(string.format("No past session matched: %s", query))
    return
  end

  if pcall(require, "telescope") then
    M._show_telescope(query, results)
  else
    M._show_native(query, results)
  end
end

---@param query string
---@param results Vibing.Session.Search.Result[]
function M._show_telescope(query, results)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 24 }, -- 分類
      { width = 16 }, -- 日時
      { width = 6 }, -- CLI
      { remaining = true }, -- 題名
    },
  })

  ---@param prompt_bufnr number
  ---@param open fun(result: Vibing.Session.Search.Result): boolean
  local function open_selected(prompt_bufnr, open)
    local entry = action_state.get_selected_entry()
    if not entry then
      return
    end
    actions.close(prompt_bufnr)
    open(entry.value)
  end

  pickers
    .new({}, {
      prompt_title = string.format("Session Search: %s (<CR> resume, <C-h> hand off)", query),
      finder = finders.new_table({
        results = results,
        entry_maker = function(result)
          return {
            value = result,
            ordinal = table.concat({ result.group, result.title, result.summary, result.cwd or "" }, " "),
            display = function(entry)
              return displayer({
                { entry.value.group, "TelescopeResultsComment" },
                { SessionAnswer.short_date(entry.value.updated_at), "TelescopeResultsNumber" },
                { entry.value.backend, "TelescopeResultsConstant" },
                { title_of(entry.value), "TelescopeResultsIdentifier" },
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Session",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, M.preview_lines(entry.value))
          vim.bo[self.state.bufnr].filetype = "markdown"
          vim.wo[self.state.winid].wrap = true
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          open_selected(prompt_bufnr, SessionOpener.resume)
        end)
        map({ "i", "n" }, "<C-h>", function()
          open_selected(prompt_bufnr, SessionOpener.handoff)
        end)
        return true
      end,
    })
    :find()
end

---@param query string
---@param results Vibing.Session.Search.Result[]
function M._show_native(query, results)
  vim.ui.select(results, {
    prompt = string.format("Sessions matching: %s", query),
    format_item = function(result)
      return string.format(
        "[%s] %s  %s  %s",
        result.group,
        SessionAnswer.short_date(result.updated_at),
        result.backend,
        title_of(result)
      )
    end,
  }, function(choice)
    if not choice then
      return
    end
    vim.ui.select({ "resume", "hand off" }, { prompt = "Open as" }, function(how)
      if how == "resume" then
        SessionOpener.resume(choice)
      elseif how == "hand off" then
        SessionOpener.handoff(choice)
      end
    end)
  end)
end

return M
