---@class Vibing.OutputBuffer
---@field buf number?
---@field win number?
---@field _chunk_buffer string 未フラッシュのチャンクを蓄積するバッファ
---@field _chunk_timer any チャンクフラッシュ用のタイマー
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

---@return Vibing.OutputBuffer
function OutputBuffer:new()
  local instance = setmetatable({}, OutputBuffer)
  instance.buf = nil
  instance.win = nil
  instance._chunk_buffer = ""
  instance._chunk_timer = nil
  return instance
end

---出力ウィンドウを開く
---@param title string
function OutputBuffer:open(title)
  self:_create_buffer(title)
  self:_create_window()
  self:_setup_keymaps()
end

---ウィンドウを閉じる
function OutputBuffer:close()
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
function OutputBuffer:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---バッファを作成
---@param title string
function OutputBuffer:_create_buffer(title)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].filetype = "markdown"
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false
  vim.api.nvim_buf_set_name(self.buf, "vibing://" .. title)

  -- タイトルを設定
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {
    "# " .. title,
    "",
    "Loading...",
  })
end

---フローティングウィンドウを作成
function OutputBuffer:_create_window()
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Vibing ",
    title_pos = "center",
  })

  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
end

---キーマップを設定
function OutputBuffer:_setup_keymaps()
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, desc = "Close output" })

  vim.keymap.set("n", "<Esc>", function()
    self:close()
  end, { buffer = self.buf, desc = "Close output" })
end

---コンテンツを設定
---@param content string
function OutputBuffer:set_content(content)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, lines)
end

---バッファリングされたチャンクをフラッシュしてバッファに書き込む
function OutputBuffer:_flush_chunks()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  if self._chunk_buffer == "" then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  -- バッファリングされた全チャンクを処理
  local chunk_lines = vim.split(self._chunk_buffer, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(self.buf, #lines - 1, #lines, false, chunk_lines)

  -- バッファをクリア
  self._chunk_buffer = ""
end

---ストリーミングチャンクを追加（バッファリング有効）
---@param chunk string
---@param is_first boolean
function OutputBuffer:append_chunk(chunk, is_first)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  if is_first then
    -- "Loading..."を削除
    vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, { "" })
    self._chunk_buffer = ""
  end

  -- チャンクをバッファに蓄積
  self._chunk_buffer = self._chunk_buffer .. chunk

  -- 既存のタイマーがあればキャンセル
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
  end

  -- 50ms後にフラッシュするタイマーを設定（複数チャンクをまとめて処理）
  self._chunk_timer = vim.fn.timer_start(50, function()
    self:_flush_chunks()
    self._chunk_timer = nil
  end)
end

---エラーを表示
---@param error_msg string
function OutputBuffer:show_error(error_msg)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, {
    "",
    "**Error:**",
    "",
    error_msg,
  })
end

return OutputBuffer
