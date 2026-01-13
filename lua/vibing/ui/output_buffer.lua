---@class Vibing.OutputBuffer
---@field buf number?
---@field win number?
---@field _chunk_buffer string 未フラッシュのチャンクを蓄積するバッファ
---@field _chunk_timer any チャンクフラッシュ用のタイマー
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

---@return Vibing.OutputBuffer
-- Create a new OutputBuffer instance.
-- Initializes a new output buffer with fields set to nil (buf, win) and empty chunk buffer.
-- @return Vibing.OutputBuffer A new OutputBuffer instance.
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
-- Open the output window.
-- Creates a buffer, opens a centered floating window, and sets up keymaps.
-- @param title string Title to display in the window header and buffer.
function OutputBuffer:open(title)
  self:_create_buffer(title)
  self:_create_window()
  self:_setup_keymaps()
end

---ウィンドウを閉じる
-- Close the output window.
-- Stops any active chunk flush timer and closes the floating window if it's valid.
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
-- Check if the output window is currently open.
-- @return boolean True if the window is valid and open, false otherwise.
function OutputBuffer:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---バッファを作成
---@param title string
function OutputBuffer:_create_buffer(title)
  local Factory = require("vibing.infrastructure.ui.factory")
  self.buf = Factory.create_buffer({
    filetype = "vibing",
    buftype = "nofile",
    modifiable = true,
  })
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
  local Factory = require("vibing.infrastructure.ui.factory")
  self.win = Factory.create_float({
    width = 0.6,
    height = 0.6,
    border = "rounded",
    title = "Vibing",
  }, self.buf)
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
-- Set the complete content of the output buffer.
-- Replaces all content after the title header with the provided text.
-- @param content string The content to display (will be split into lines).
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
-- Append a streaming chunk to the output buffer (with buffering enabled).
-- Accumulates chunks and flushes them after 50ms to reduce render overhead.
-- On the first chunk, removes the "Loading..." placeholder.
-- @param chunk string The text chunk to append.
-- @param is_first boolean True if this is the first chunk, false otherwise.
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
-- Display an error message in the output buffer.
-- Replaces content with a formatted error section.
-- @param error_msg string The error message to display.
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
