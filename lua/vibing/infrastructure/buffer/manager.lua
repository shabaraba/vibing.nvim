---@class Vibing.Infrastructure.BufferManager
---Neovimバッファ操作のインフラ層
local M = {}

---バッファの内容を取得
---@param bufnr number? バッファ番号（nilで現在のバッファ）
---@return string[] lines
function M.get_lines(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---バッファの内容を設定
---@param lines string[]
---@param bufnr number?
function M.set_lines(lines, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

---バッファのファイルパスを取得
---@param bufnr number?
---@return string
function M.get_name(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_name(bufnr)
end

---バッファが有効か確認
---@param bufnr number
---@return boolean
function M.is_valid(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
end

---バッファがロード済みか確認
---@param bufnr number
---@return boolean
function M.is_loaded(bufnr)
  return vim.api.nvim_buf_is_loaded(bufnr)
end

---全てのロード済みバッファを取得
---@return number[]
function M.list_loaded()
  local bufs = vim.api.nvim_list_bufs()
  return vim.tbl_filter(function(buf)
    return vim.api.nvim_buf_is_loaded(buf)
  end, bufs)
end

---バッファオプションを設定
---@param bufnr number
---@param name string
---@param value any
function M.set_option(bufnr, name, value)
  vim.bo[bufnr][name] = value
end

---バッファオプションを取得
---@param bufnr number
---@param name string
---@return any
function M.get_option(bufnr, name)
  return vim.bo[bufnr][name]
end

---新しいバッファを作成
---@param listed boolean
---@param scratch boolean
---@return number
function M.create(listed, scratch)
  return vim.api.nvim_create_buf(listed, scratch)
end

---バッファを削除
---@param bufnr number
---@param force boolean?
function M.delete(bufnr, force)
  vim.api.nvim_buf_delete(bufnr, { force = force or false })
end

return M
