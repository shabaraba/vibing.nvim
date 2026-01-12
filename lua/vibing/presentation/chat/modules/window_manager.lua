local M = {}

---ウィンドウを作成
---@param buf number バッファ番号
---@param win_config table ウィンドウ設定
---@return number? winnr ウィンドウ番号（"back"の場合はnil）
function M.create_window(buf, win_config)
  local width = math.floor(vim.o.columns * win_config.width)
  local height = math.floor(vim.o.lines * (win_config.height or 0.4))
  local win

  if win_config.position == "current" then
    -- 現在のウィンドウで新規バッファを開く
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif win_config.position == "right" then
    vim.cmd("botright vsplit")
    vim.cmd("vertical resize " .. width)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif win_config.position == "left" then
    vim.cmd("topleft vsplit")
    vim.cmd("vertical resize " .. width)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif win_config.position == "top" then
    vim.cmd("topleft split")
    vim.cmd("resize " .. height)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif win_config.position == "bottom" then
    vim.cmd("botright split")
    vim.cmd("resize " .. height)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif win_config.position == "back" then
    -- バッファのみ作成、ウィンドウは作成しない
    -- バッファはlistされているので、:bnext等でアクセス可能
    return nil
  else
    -- float
    local float_height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - float_height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = float_height,
      row = row,
      col = col,
      style = "minimal",
      border = win_config.border,
    })
  end

  return win
end

---wrap設定を適用
---@param winnr number ウィンドウ番号
function M.apply_wrap_config(winnr)
  local ok, ui_utils = pcall(require, "vibing.core.utils.ui")
  if ok and winnr then
    pcall(ui_utils.apply_wrap_config, winnr)
  end
end

return M
