---@class Vibing.Application.ContextManager
---コンテキスト管理ユースケース
local M = {}

local Collector = require("vibing.infrastructure.context.collector")
local notify = require("vibing.core.utils.notify")

---@type string[]
M.manual_contexts = {}

---ファイルをコンテキストに追加
---@param path string?
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
    M._copy_to_clipboard(context)
    notify.info(string.format("Added context: %s (copied to clipboard)", context), "Context")
  end
end

---選択範囲をコンテキストに追加
function M.add_selection()
  local selection_context = M.get_selection()
  if not selection_context then
    notify.warn("No selection available", "Context")
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)

  if file_path == "" then
    notify.warn("Current buffer has no file path", "Context")
    return
  end

  local relative = Collector._to_relative_path(file_path)
  M.manual_contexts = vim.tbl_filter(function(ctx)
    return not ctx:match("^@file:" .. vim.pesc(relative) .. "[:\n]")
  end, M.manual_contexts)

  table.insert(M.manual_contexts, selection_context)
  M._copy_to_clipboard(selection_context)

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  notify.info(string.format("Added selection: %s:L%d-L%d (copied to clipboard)", relative, start_pos[2], end_pos[2]), "Context")
end

---コンテキストをクリア
function M.clear()
  M.manual_contexts = {}
  notify.info("Context cleared", "Context")
end

---全コンテキストを取得
---@param auto_context boolean
---@return string[]
function M.get_all(auto_context)
  local contexts = vim.deepcopy(M.manual_contexts)
  local seen_paths = {}

  -- 手動コンテキストのパスを正規化して追跡
  for _, ctx in ipairs(contexts) do
    local normalized = M._extract_and_normalize_path(ctx)
    seen_paths[normalized] = true
  end

  if auto_context then
    local auto = Collector.collect_buffers()
    for _, ctx in ipairs(auto) do
      local normalized = M._extract_and_normalize_path(ctx)
      if not seen_paths[normalized] then
        table.insert(contexts, ctx)
        seen_paths[normalized] = true
      end
    end
  end

  return contexts
end

---選択範囲のコンテキストを取得
---@return string?
function M.get_selection()
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  return Collector.collect_selection(buf, start_pos[2], end_pos[2])
end

---表示用フォーマット
---@return string
function M.format_for_display()
  local contexts = M.get_all(true)
  if #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

---@private
---コンテキストをクリップボードにコピー
---@param context string コンテキスト文字列
function M._copy_to_clipboard(context)
  -- クリップボードプロバイダーを確認
  if vim.fn.has("clipboard") == 1 then
    vim.fn.setreg("+", context)
  else
    -- クリップボードサポートがない場合は無名レジスタに設定
    vim.fn.setreg('"', context)
  end
end

---@private
---コンテキスト文字列からファイルパスを抽出して正規化
---@param context string @file:path または @file:path:L10-L25 形式
---@return string 正規化された絶対パス
function M._extract_and_normalize_path(context)
  -- @file:path または @file:path:L10-L25 からpathを抽出
  local path = context:match("^@file:([^:]+)")
  if not path then
    return context
  end

  -- 絶対パスに変換して正規化（シンボリックリンク解決含む）
  local absolute = vim.fn.fnamemodify(path, ":p")
  return absolute
end

return M
