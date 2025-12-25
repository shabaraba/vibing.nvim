---@class Vibing.Collector
local M = {}

local BufferIdentifier = require("vibing.utils.buffer_identifier")

-- cwdのキャッシュ（パフォーマンス最適化）
local _cwd_cache = nil
local _cwd_cache_time = 0

---キャッシュされたcwdを取得（1秒間キャッシュ）
---@return string
local function get_cached_cwd()
  local now = vim.loop.now()
  if _cwd_cache and (now - _cwd_cache_time) < 1000 then
    return _cwd_cache
  end
  _cwd_cache = vim.fn.getcwd()
  _cwd_cache_time = now
  return _cwd_cache
end

-- DirChangedイベントでキャッシュを無効化
vim.api.nvim_create_autocmd("DirChanged", {
  group = vim.api.nvim_create_augroup("VibingCwdCache", { clear = true }),
  callback = function()
    _cwd_cache = nil
    _cwd_cache_time = 0
  end,
})

---開いているバッファから@file:形式のコンテキストを収集
---@return string[]
function M.collect_buffers()
  local contexts = {}
  local bufs = vim.api.nvim_list_bufs()

  for _, buf in ipairs(bufs) do
    if M._is_valid_buffer(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" then
        local relative = M._to_relative_path(path)
        table.insert(contexts, "@file:" .. relative)
      end
    end
  end

  return contexts
end

---ビジュアル選択範囲から@file:path:L10-L25形式のメンションと実際のコンテンツを作成
---@param buf number
---@param start_line number
---@param end_line number
---@return string?
function M.collect_selection(buf, start_line, end_line)
  local path = vim.api.nvim_buf_get_name(buf)

  -- 新規バッファ（名前なし）の場合、特別な識別子を使用
  local relative
  if path == "" then
    relative = BufferIdentifier.create_identifier(buf)
  else
    relative = M._to_relative_path(path)
  end

  local mention = string.format("@file:%s:L%d-L%d", relative, start_line, end_line)

  -- 選択範囲の実際のコンテンツを取得
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if #lines == 0 then
    return mention
  end

  -- ファイルタイプからコードブロックの言語を推定
  local filetype = vim.bo[buf].filetype
  local lang = filetype ~= "" and filetype or ""

  -- メンション + コードブロック形式で返す
  local content = table.concat(lines, "\n")
  return string.format("%s\n```%s\n%s\n```", mention, lang, content)
end

---ファイルパスから@file:形式のコンテキストを作成
---@param path string
---@return string
function M.file_to_context(path)
  local expanded = vim.fn.expand(path)
  local absolute = vim.fn.fnamemodify(expanded, ":p")
  local relative = M._to_relative_path(absolute)
  return "@file:" .. relative
end

---バッファがコンテキストとして有効かチェック
---@param buf number
---@return boolean
function M._is_valid_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "" then
    return false
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return false
  end

  -- 除外パターン
  local exclude_patterns = {
    "%.git/",
    "node_modules/",
    "%.vibing",
  }

  for _, pattern in ipairs(exclude_patterns) do
    if name:match(pattern) then
      return false
    end
  end

  return true
end

---絶対パスを相対パスに変換（cwdキャッシュ使用）
---@param path string
---@return string
function M._to_relative_path(path)
  local cwd = get_cached_cwd()
  if path:sub(1, #cwd) == cwd then
    local relative = path:sub(#cwd + 2)
    return relative ~= "" and relative or path
  end
  return path
end

return M
