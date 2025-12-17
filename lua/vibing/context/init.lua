local Collector = require("vibing.context.collector")
local notify = require("vibing.utils.notify")

---@class Vibing.Context
---コンテキスト管理モジュール
---手動追加されたファイルと自動収集される開いているバッファを統合管理
---@field manual_contexts string[] 手動で追加されたコンテキストファイルの配列（@file:path形式）
local M = {}

---手動で追加されたコンテキストファイルのリスト
---@type string[]
M.manual_contexts = {}

---ファイルをコンテキストに手動追加
---pathが指定された場合はそのファイル、省略時は現在のバッファを追加
---@file:path形式に変換して重複チェック後にmanual_contextsに追加
---@param path? string ファイルパス（省略時は現在のバッファ、空文字列も現在のバッファとして扱う）
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

---手動で追加されたコンテキストを全てクリア
---自動コンテキスト（開いているバッファ）は設定に従い継続
function M.clear()
  M.manual_contexts = {}
  notify.info("Context cleared", "Context")
end

---全コンテキストを取得（手動 + 自動）
---手動コンテキストを優先し、auto_contextがtrueの場合は開いているバッファも追加
---重複は自動的に除外される
---@param auto_context boolean 自動コンテキスト（開いているバッファ）を含めるか
---@return string[] @file:path形式のコンテキスト配列
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

---現在のビジュアル選択範囲からコンテキストを取得
---インラインアクション（fix, explain等）で選択範囲を@file:path:L10-L25形式で取得
---@return string? @file:path:L10-L25形式のコンテキスト（選択範囲なしの場合はnil）
function M.get_selection()
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  return Collector.collect_selection(buf, start_line, end_line)
end

---コンテキストを表示用フォーマットで取得
---チャットバッファのコンテキスト表示行やステータス表示に使用
---カンマ区切りの一覧を返す（コンテキストなしの場合は"No context"）
---@return string カンマ区切りのコンテキスト一覧（例: "@file:foo.lua, @file:bar.lua"）
function M.format_for_display()
  local contexts = M.get_all(true)
  if #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

return M
