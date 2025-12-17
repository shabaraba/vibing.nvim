local Collector = require("vibing.context.collector")
local notify = require("vibing.utils.notify")

---@class Vibing.Context
---@field manual_contexts string[] 手動追加されたコンテキスト
local M = {}

M.manual_contexts = {}

---手動でコンテキストを追加
---@param path? string ファイルパス（省略時は現在のバッファ）
function M.add(path)
  local context
  if path and path ~= "" then
    context = Collector.file_to_context(path)
  else
    local buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
      notify.warn("Current buffer has no file path", "Context")
      return
    end
    context = Collector.file_to_context(name)
  end

  if not vim.tbl_contains(M.manual_contexts, context) then
    table.insert(M.manual_contexts, context)
    notify.info(string.format("Added context: %s", context), "Context")
  end
end

---コンテキストをクリア
function M.clear()
  M.manual_contexts = {}
  notify.info("Context cleared", "Context")
end

---全コンテキストを取得（自動 + 手動）
---@param auto_context boolean 自動コンテキストを含めるか
---@return string[]
function M.get_all(auto_context)
  local contexts = {}

  -- 手動コンテキストを追加
  for _, ctx in ipairs(M.manual_contexts) do
    table.insert(contexts, ctx)
  end

  -- 自動コンテキストを追加
  if auto_context then
    local auto = Collector.collect_buffers()
    for _, ctx in ipairs(auto) do
      if not vim.tbl_contains(contexts, ctx) then
        table.insert(contexts, ctx)
      end
    end
  end

  return contexts
end

---ビジュアル選択からコンテキストを取得
---@return string?
function M.get_selection()
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  return Collector.collect_selection(buf, start_line, end_line)
end

---コンテキストを表示用フォーマットで取得
---@return string
function M.format_for_display()
  local contexts = M.get_all(true)
  if #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

return M
