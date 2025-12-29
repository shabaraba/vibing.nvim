---@class Vibing.Presentation.Window
---ウィンドウ管理の共通クラス
local Window = {}
Window.__index = Window

---新しいウィンドウマネージャーを作成
---@return Vibing.Presentation.Window
function Window:new()
  local instance = setmetatable({}, self)
  instance.buf = nil
  instance.win = nil
  return instance
end

---フローティングウィンドウを作成
---@param opts table
---@return number win_id
function Window:create_float(opts)
  local width = opts.width or math.floor(vim.o.columns * 0.6)
  local height = opts.height or math.floor(vim.o.lines * 0.6)
  local row = opts.row or math.floor((vim.o.lines - height) / 2)
  local col = opts.col or math.floor((vim.o.columns - width) / 2)

  self.buf = vim.api.nvim_create_buf(false, true)

  self.win = vim.api.nvim_open_win(self.buf, opts.enter ~= false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
  })

  local ui_utils = require("vibing.utils.ui")
  ui_utils.apply_wrap_config(self.win)

  return self.win
end

---右分割ウィンドウを作成
---@param opts table
---@return number win_id
function Window:create_vsplit_right(opts)
  vim.cmd("vsplit")
  vim.cmd("wincmd l")

  self.win = vim.api.nvim_get_current_win()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(self.win, self.buf)

  if opts.width then
    local width = opts.width < 1 and math.floor(vim.o.columns * opts.width) or opts.width
    vim.api.nvim_win_set_width(self.win, width)
  end

  local ui_utils = require("vibing.utils.ui")
  ui_utils.apply_wrap_config(self.win)

  return self.win
end

---ウィンドウを閉じる
function Window:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

---ウィンドウが有効か確認
---@return boolean
function Window:is_valid()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---バッファが有効か確認
---@return boolean
function Window:is_buf_valid()
  return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
end

return Window
