local M = {}

local DEFAULT_WIDTH_RATIO = 0.4
local DEFAULT_HEIGHT_RATIO = 0.4
---floatはエディタ全体を覆わないよう、高さ未指定時は画面の8割に収める
local DEFAULT_FLOAT_HEIGHT_RATIO = 0.8

---サイズ指定を実際のセル数へ解決する
---0-1の小数は`total`に対する比率、1以上はそのまま絶対値として扱う
---(presentation/common/window.lua と同じ規約)
---@param value number? 設定値
---@param total number 画面の幅または高さ
---@param default_ratio number valueがnilのときに使う比率
---@return number cells
local function resolve_size(value, total, default_ratio)
  local size = value or default_ratio
  if size < 1 then
    size = math.floor(total * size)
  else
    size = math.floor(size)
  end
  -- 0やマイナス、画面をはみ出す絶対値でnvim_open_winが失敗しないよう丸める
  return math.max(1, math.min(size, total))
end

M._resolve_size = resolve_size

---ウィンドウを作成
---@param buf number バッファ番号
---@param win_config table ウィンドウ設定
---@return number? winnr ウィンドウ番号（"back"の場合はnil）
function M.create_window(buf, win_config)
  local width = resolve_size(win_config.width, vim.o.columns, DEFAULT_WIDTH_RATIO)
  local height = resolve_size(win_config.height, vim.o.lines, DEFAULT_HEIGHT_RATIO)
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
    -- heightが設定されていればfloatでも尊重する（未設定時のみ従来の0.8）
    local float_height = resolve_size(win_config.height, vim.o.lines, DEFAULT_FLOAT_HEIGHT_RATIO)
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
---@param bufnr? number バッファ番号（省略時はウィンドウから取得）
function M.apply_wrap_config(winnr, bufnr)
  local ok, ui_utils = pcall(require, "vibing.core.utils.ui")
  if ok and winnr then
    -- force=true: ChatBufferから呼ばれる場合は常にチャットバッファなので強制適用
    pcall(ui_utils.apply_wrap_config, winnr, bufnr, true)
  end
end

return M
