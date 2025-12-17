---@class Vibing.Collector
local M = {}

---開いているバッファから@file:形式のコンテキストを収集
---無効なバッファ、特殊バッファ、除外パターンに一致するバッファはスキップ
---@return string[] contexts @file:path 形式の文字列配列
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
---バッファに名前がない場合は nil を返す
---@param buf number バッファ番号
---@param start_line number 開始行番号（1-indexed）
---@param end_line number 終了行番号（1-indexed）
---@return string? mention @file:path:Lstart-Lend 形式の文字列、またはnil
function M.collect_selection(buf, start_line, end_line)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end

  local relative = M._to_relative_path(path)
  return string.format("@file:%s:L%d-L%d", relative, start_line, end_line)
end

---ファイルパスから@file:形式のコンテキストを作成
---パスを展開し、絶対パスに変換してから相対パスに変換
---@param path string ファイルパス（相対または絶対）
---@return string context @file:path 形式の文字列
function M.file_to_context(path)
  local expanded = vim.fn.expand(path)
  local absolute = vim.fn.fnamemodify(expanded, ":p")
  local relative = M._to_relative_path(absolute)
  return "@file:" .. relative
end

---バッファがコンテキストとして有効かチェック
---有効: 通常ファイル、ロード済み、除外パターンに非該当
---無効: 特殊バッファ、git/node_modules/.vibingパス
---@param buf number バッファ番号
---@return boolean is_valid バッファがコンテキストとして有効な場合true
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
---現在のワーキングディレクトリからの相対パスを返す
---相対パスに変換できない場合は絶対パスをそのまま返す
---@param path string 絶対パス
---@return string relative_path 相対パスまたは絶対パス
function M._to_relative_path(path)
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    local relative = path:sub(#cwd + 2)
    return relative ~= "" and relative or path
  end
  return path
end

return M
