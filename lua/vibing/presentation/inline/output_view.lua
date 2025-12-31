---@class Vibing.Presentation.OutputView
---出力バッファビュー
local OutputView = {}
OutputView.__index = OutputView

---新しい出力ビューを作成
---@return Vibing.Presentation.OutputView
function OutputView:new()
  local instance = setmetatable({}, self)
  instance.buf = nil
  instance.win = nil
  instance._chunk_buffer = ""
  instance._chunk_timer = nil
  return instance
end

---出力ウィンドウを開く
---@param title string
function OutputView:open(title)
  self:_create_buffer(title)
  self:_create_window()
  self:_setup_keymaps()
end

---バッファを作成
---@param title string
function OutputView:_create_buffer(title)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].filetype = "vibing"
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false
  vim.api.nvim_buf_set_name(self.buf, "vibing://" .. title)
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { "# " .. title, "", "Loading..." })
end

---フローティングウィンドウを作成
function OutputView:_create_window()
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.6)

  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Vibing ",
    title_pos = "center",
  })

end

---キーマップを設定
function OutputView:_setup_keymaps()
  local close = function() self:close() end
  vim.keymap.set("n", "q", close, { buffer = self.buf, desc = "Close output" })
  vim.keymap.set("n", "<Esc>", close, { buffer = self.buf, desc = "Close output" })
end

---ウィンドウを閉じる
function OutputView:close()
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

---ウィンドウが開いているか
---@return boolean
function OutputView:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---コンテンツを設定
---@param content string
function OutputView:set_content(content)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, vim.split(content, "\n", { plain = true }))
end

---チャンクをフラッシュ
function OutputView:_flush_chunks()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) or self._chunk_buffer == "" then return end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_line = lines[#lines] or ""
  local chunk_lines = vim.split(self._chunk_buffer, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(self.buf, #lines - 1, #lines, false, chunk_lines)
  self._chunk_buffer = ""
end

---チャンクを追加
---@param chunk string
---@param is_first boolean?
function OutputView:append_chunk(chunk, is_first)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end

  if is_first then
    vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, { "" })
    self._chunk_buffer = ""
  end

  self._chunk_buffer = self._chunk_buffer .. chunk

  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
  end

  self._chunk_timer = vim.fn.timer_start(50, function()
    self:_flush_chunks()
    self._chunk_timer = nil
  end)
end

---エラーを表示
---@param error_msg string
function OutputView:show_error(error_msg)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, { "", "**Error:**", "", error_msg })
end

return OutputView
