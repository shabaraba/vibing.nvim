---@class Vibing.Utils.Diff
---Diffバッファ操作のユーティリティ
---Inline Previewで使用するDiff表示バッファの作成と更新を提供
local M = {}

---Diffバッファを作成
---filetype="diff"でシンタックスハイライトを有効化
---@param diff_lines string[] Diff内容の行配列
---@return number バッファ番号
function M.create_diff_buffer(diff_lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "diff")
  vim.api.nvim_buf_set_option(buf, "modifiable", true)

  -- Diff内容を設定
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  return buf
end

---Diffバッファの内容を更新
---@param bufnr number バッファ番号
---@param diff_lines string[] 新しいDiff内容の行配列
function M.update_diff_buffer(bufnr, diff_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- 行数制限（1000行まで）
  local MAX_LINES = 1000
  local lines = diff_lines
  if #lines > MAX_LINES then
    lines = vim.list_slice(lines, 1, MAX_LINES)
    table.insert(lines, "")
    table.insert(lines, "--- Diff truncated (too large) ---")
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

---空のDiffバッファを作成（変更なし時のプレースホルダー）
---@param message string? 表示メッセージ（デフォルト: "No changes detected"）
---@return number バッファ番号
function M.create_empty_diff_buffer(message)
  message = message or "No changes detected"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "modifiable", true)

  local lines = {
    "",
    message,
    "",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  return buf
end

return M
