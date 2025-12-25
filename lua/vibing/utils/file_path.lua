---@class Vibing.Utils.FilePath
---ファイルパス検出と操作のユーティリティ
local M = {}

local BufferIdentifier = require("vibing.utils.buffer_identifier")

---カーソルが "## Modified Files" セクション内のファイルパス上にあるかチェック
---現在行がファイルパスであり、かつ "## Modified Files" セクション内にある場合、ファイルパスを返す
---@param buf number バッファ番号
---@return string? ファイルパス（セクション内のファイルパス上にない場合は nil）
function M.is_cursor_on_file_path(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local total_lines = vim.api.nvim_buf_line_count(buf)

  -- 現在行の内容を取得
  local current_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not current_line or current_line == "" then
    return nil
  end

  -- ファイルパスの形式をチェック（空白をトリム）
  local trimmed_line = current_line:match("^%s*(.-)%s*$")
  if not trimmed_line or trimmed_line == "" then
    return nil
  end

  -- "##" で始まる行はヘッダーなので除外
  if trimmed_line:match("^##") then
    return nil
  end

  -- 後方に "## Modified Files" ヘッダーを探す
  local found_modified_files_header = false
  for i = row - 1, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line then
      if line:match("^##%s+Modified%s+Files") then
        found_modified_files_header = true
        break
      elseif line:match("^##%s+") and not line:match("^##%s+Modified%s+Files") then
        -- 別のセクションヘッダーに到達したので、Modified Filesセクション外
        return nil
      end
    end
  end

  if not found_modified_files_header then
    return nil
  end

  -- 前方に次のセクションヘッダーがあるかチェック
  for i = row + 1, total_lines do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line and line:match("^##%s+") then
      -- 次のセクションに到達したので、Modified Filesセクション内ではない
      break
    end
  end

  -- Check if this is a [Buffer N] identifier
  if BufferIdentifier.is_buffer_identifier(trimmed_line) then
    -- Extract buffer number and check if buffer exists
    local bufnr = BufferIdentifier.extract_bufnr(trimmed_line)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return trimmed_line  -- Return as-is, don't normalize
    end
    return nil
  end

  -- ファイルの存在確認
  -- 相対パスまたは絶対パスを正規化
  local file_path = vim.fn.fnamemodify(trimmed_line, ":p")
  if vim.fn.filereadable(file_path) == 1 or vim.fn.isdirectory(file_path) == 1 then
    return file_path
  end

  return nil
end

---ファイルを開く
---既に開かれている場合はそのバッファに切り替え、そうでない場合は新規に開く
---@param file_path string ファイルパス（絶対パス）または[Buffer N]形式
function M.open_file(file_path)
  -- Check if this is a [Buffer N] identifier
  if BufferIdentifier.is_buffer_identifier(file_path) then
    local bufnr = BufferIdentifier.extract_bufnr(file_path)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_current_buf(bufnr)
    else
      vim.notify("[vibing] Buffer not found: " .. file_path, vim.log.levels.ERROR)
    end
    return
  end

  -- ファイルの存在確認
  if vim.fn.filereadable(file_path) == 0 then
    vim.notify("[vibing] File not found: " .. file_path, vim.log.levels.ERROR)
    return
  end

  -- 既に開かれているバッファがあるか確認
  local buf = vim.fn.bufnr(file_path)
  if buf ~= -1 then
    -- 既存のバッファに切り替え
    vim.api.nvim_set_current_buf(buf)
  else
    -- 新規に開く
    vim.cmd.edit(vim.fn.fnameescape(file_path))
  end
end

return M
