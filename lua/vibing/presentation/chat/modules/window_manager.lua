local Factory = require("vibing.infrastructure.ui.factory")

local M = {}

---分割ウィンドウの既定サイズ（幅・高さとも画面の4割）
local DEFAULT_SPLIT_RATIO = 0.4
---floatはエディタ全体を覆わないよう、高さ未指定時は画面の8割に収める
local DEFAULT_FLOAT_HEIGHT_RATIO = 0.8

---位置ごとの分割コマンド。resizeの向きだけが違う4分岐をまとめる
local SPLITS = {
  right = { cmd = "botright vsplit", vertical = true },
  left = { cmd = "topleft vsplit", vertical = true },
  top = { cmd = "topleft split" },
  bottom = { cmd = "botright split" },
}

---サイズ指定を実際のセル数へ解決する
---0-1の小数は`total`に対する比率、1以上はそのまま絶対値（比率/絶対値の規約は Factory と共通）
---@param value number? 設定値
---@param total number 画面の幅または高さ
---@param default_ratio number valueがnilのときに使う比率
---@return number cells
local function resolve_size(value, total, default_ratio)
  local size = Factory.calculate_size(value or default_ratio, total)
  -- 0やマイナス、画面をはみ出す絶対値でnvim_open_winが失敗しないよう丸める
  return math.max(1, math.min(size, total))
end

---ウィンドウを作成
---@param buf number バッファ番号
---@param win_config table ウィンドウ設定
---@return number? winnr ウィンドウ番号（"back"の場合はnil）
function M.create_window(buf, win_config)
  if win_config.position == "current" then
    -- 現在のウィンドウで新規バッファを開く
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  elseif win_config.position == "back" then
    -- バッファのみ作成、ウィンドウは作成しない
    -- バッファはlistされているので、:bnext等でアクセス可能
    return nil
  end

  local split = SPLITS[win_config.position]
  if split then
    vim.cmd(split.cmd)
    if split.vertical then
      vim.cmd("vertical resize " .. resolve_size(win_config.width, vim.o.columns, DEFAULT_SPLIT_RATIO))
    else
      vim.cmd("resize " .. resolve_size(win_config.height, vim.o.lines, DEFAULT_SPLIT_RATIO))
    end
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end

  local width = resolve_size(win_config.width, vim.o.columns, DEFAULT_SPLIT_RATIO)
  local height = resolve_size(win_config.height, vim.o.lines, DEFAULT_FLOAT_HEIGHT_RATIO)

  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = win_config.border,
  })
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
