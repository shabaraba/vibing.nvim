local M = {}

---アシスタント応答を開始
---@param buf number バッファ番号
function M.start_response(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local new_lines = {
    "",
    "## Assistant",
    "",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, new_lines)
end

---バッファリングされたチャンクをフラッシュ
---@param buf number バッファ番号
---@param win number? ウィンドウ番号
---@param chunk_buffer string バッファリング内容
---@return string empty_string 空文字列（バッファクリア用）
function M.flush_chunks(buf, win, chunk_buffer)
  if not vim.api.nvim_buf_is_valid(buf) or chunk_buffer == "" then
    return ""
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  local chunk_lines = vim.split(chunk_buffer, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(buf, #lines - 1, #lines, false, chunk_lines)

  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local current_line = cursor[1]
      local old_line_count = #lines

      if current_line >= old_line_count then
        local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local line_count = #new_lines
        if line_count > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
        end
      end
    end
  end

  return ""
end

return M
