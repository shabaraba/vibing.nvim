---@class Vibing.Utils.BufferIdentifier
---バッファ識別子（[Buffer N]形式）の操作ユーティリティ
local M = {}

-- バッファ識別子のパターン
M.PATTERN = "^%[Buffer (%d+)%]$"

---文字列がバッファ識別子かどうかをチェック
---@param str string チェックする文字列
---@return boolean true if buffer identifier
function M.is_buffer_identifier(str)
  return str:match(M.PATTERN) ~= nil
end

---バッファ識別子からバッファ番号を抽出
---@param str string バッファ識別子（例: "[Buffer 3]"）
---@return number? バッファ番号、無効な場合はnil
function M.extract_bufnr(str)
  local num_str = str:match(M.PATTERN)
  if not num_str then
    return nil
  end

  local bufnr = tonumber(num_str)
  -- Validate buffer number is in reasonable range
  if bufnr and bufnr > 0 and bufnr < 2147483647 then
    return bufnr
  end
  return nil
end

---バッファ番号からバッファ識別子を作成
---@param bufnr number バッファ番号
---@return string バッファ識別子（例: "[Buffer 3]"）
function M.create_identifier(bufnr)
  if type(bufnr) ~= "number" or bufnr <= 0 then
    error("Invalid buffer number: " .. tostring(bufnr))
  end
  return string.format("[Buffer %d]", bufnr)
end

---ファイルパスを正規化（バッファ識別子はそのまま、ファイルパスは絶対パス化）
---@param file_path string ファイルパスまたはバッファ識別子
---@return string 正規化されたパス
function M.normalize_path(file_path)
  if M.is_buffer_identifier(file_path) then
    return file_path -- Don't normalize buffer identifiers
  else
    return vim.fn.fnamemodify(file_path, ":p")
  end
end

return M
