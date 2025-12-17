---@class Vibing.Collector
---コンテキスト収集モジュール
---開いているバッファ、ビジュアル選択、ファイルパスから@file:path形式のコンテキストを生成
local M = {}

---開いているバッファから@file:形式のコンテキストを収集
---全バッファをスキャンし、有効なファイルバッファのパスを相対パスに変換して@file:pathフォーマットで返す
---特殊バッファ（help, quickfix等）と除外パターン（.git, node_modules等）は自動的にスキップ
---@return string[] @file:path形式のコンテキスト配列（例: {"@file:init.lua", "@file:config.lua"}）
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
---インラインアクション（fix, explain等）で選択範囲を特定する際に使用
---バッファ番号と行範囲から相対パス付きの行範囲メンションを生成
---@param buf number バッファ番号
---@param start_line number 選択開始行（1-indexed）
---@param end_line number 選択終了行（1-indexed）
---@return string? @file:path:L10-L25形式のメンション（バッファ名なしの場合はnil）
function M.collect_selection(buf, start_line, end_line)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end

  local relative = M._to_relative_path(path)
  return string.format("@file:%s:L%d-L%d", relative, start_line, end_line)
end

---ファイルパスから@file:形式のコンテキストを作成
---:VibingContextコマンドや手動コンテキスト追加で使用
---チルダ展開、絶対パス変換、相対パス変換を実施して@file:pathフォーマットで返す
---@param path string ファイルパス（相対パス、絶対パス、チルダ形式すべて対応）
---@return string @file:path形式のコンテキスト（例: "@file:lua/vibing/init.lua"）
function M.file_to_context(path)
  local expanded = vim.fn.expand(path)
  local absolute = vim.fn.fnamemodify(expanded, ":p")
  local relative = M._to_relative_path(absolute)
  return "@file:" .. relative
end

---バッファがコンテキストとして有効かチェック
---特殊バッファ（help, quickfix, terminal等）と除外パターン（.git, node_modules等）を判定
---自動コンテキスト収集（collect_buffers）で通常のファイルバッファのみを対象にする
---@param buf number バッファ番号
---@return boolean 有効なファイルバッファの場合true、特殊バッファや除外パターンに一致する場合false
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
---現在のカレントディレクトリ（cwd）を基準に相対パス化
---cwdの外にあるパスはそのまま絶対パスとして返す
---@param path string 絶対パス
---@return string 相対パス（cwd配下の場合）または元の絶対パス（cwd外の場合）
function M._to_relative_path(path)
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    local relative = path:sub(#cwd + 2)
    return relative ~= "" and relative or path
  end
  return path
end

return M
