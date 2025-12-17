---@class Vibing.Collector
local M = {}

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

---ビジュアル選択範囲から@file:path:L10-L25形式のメンションを作成
---@param buf number
---@param start_line number
---@param end_line number
---@return string?
function M.collect_selection(buf, start_line, end_line)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end

  local relative = M._to_relative_path(path)
  return string.format("@file:%s:L%d-L%d", relative, start_line, end_line)
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

---絶対パスを相対パスに変換
---@param path string
---@return string
function M._to_relative_path(path)
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    local relative = path:sub(#cwd + 2)
    return relative ~= "" and relative or path
  end
  return path
end

return M
