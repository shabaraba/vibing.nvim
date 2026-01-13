---@class Vibing.Infrastructure.UI.Factory
---UI要素（バッファ、ウィンドウ、レイアウト）を作成するファクトリーモジュール
---重複したバッファ/ウィンドウ作成コードを統合し、一貫性のあるUI生成を提供
local M = {}

---@class Vibing.UI.BufferConfig
---@field listed boolean? バッファをリストに表示するか（デフォルト: false）
---@field scratch boolean? スクラッチバッファか（デフォルト: true）
---@field modifiable boolean? 編集可能か（デフォルト: false）
---@field buftype string? バッファタイプ（nofile, prompt等）
---@field filetype string? ファイルタイプ
---@field bufhidden string? バッファ非表示時の動作（wipe, hide等）

---@class Vibing.UI.WindowConfig
---@field width number|fun():number ウィンドウ幅（絶対値または比率 0-1、または計算関数）
---@field height number|fun():number ウィンドウ高さ（絶対値または比率 0-1、または計算関数）
---@field row number? ウィンドウの行位置
---@field col number? ウィンドウの列位置
---@field relative string? 相対位置（"editor", "win", "cursor"）
---@field border string? ボーダースタイル（"single", "double", "rounded", "solid", "shadow", "none"）
---@field title string? ウィンドウタイトル
---@field title_pos string? タイトル位置（"left", "center", "right"）
---@field enter boolean? ウィンドウに入るか（デフォルト: true）
---@field zindex number? 重ね順
---@field style string? スタイル（"minimal"等）

---@class Vibing.UI.SplitConfig
---@field position "right"|"left"|"top"|"bottom" 分割位置
---@field width number? 幅（垂直分割時）
---@field height number? 高さ（水平分割時）

---幅/高さを計算（比率または絶対値をサポート）
---@param value number|fun():number 値（0-1で比率、>1で絶対値、または計算関数）
---@param total number 全体のサイズ
---@return number
local function calculate_size(value, total)
  if type(value) == "function" then
    return value()
  end
  if value < 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---新しいバッファを作成
---@param config Vibing.UI.BufferConfig?
---@return number bufnr
function M.create_buffer(config)
  config = config or {}
  local bufnr = vim.api.nvim_create_buf(
    config.listed or false,
    config.scratch ~= false -- デフォルトtrue
  )

  -- バッファオプションを設定
  if config.buftype then
    vim.bo[bufnr].buftype = config.buftype
  end
  if config.filetype then
    vim.bo[bufnr].filetype = config.filetype
  end
  if config.bufhidden then
    vim.bo[bufnr].bufhidden = config.bufhidden
  end
  if config.modifiable ~= nil then
    vim.bo[bufnr].modifiable = config.modifiable
  end

  return bufnr
end

---フローティングウィンドウを作成
---@param config Vibing.UI.WindowConfig
---@param bufnr number?
---@return number winid
---@return number bufnr
function M.create_float(config, bufnr)
  bufnr = bufnr or M.create_buffer()

  local width = calculate_size(config.width or 0.6, vim.o.columns)
  local height = calculate_size(config.height or 0.6, vim.o.lines)
  local row = config.row or math.floor((vim.o.lines - height) / 2)
  local col = config.col or math.floor((vim.o.columns - width) / 2)

  local win_config = {
    relative = config.relative or "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = config.style or "minimal",
    border = config.border or "rounded",
    zindex = config.zindex,
  }

  if config.title then
    win_config.title = " " .. config.title .. " "
    win_config.title_pos = config.title_pos or "center"
  end

  local winid = vim.api.nvim_open_win(bufnr, config.enter ~= false, win_config)

  return winid, bufnr
end

---分割ウィンドウを作成
---@param split_config Vibing.UI.SplitConfig
---@param bufnr number?
---@return number winid
---@return number bufnr
function M.create_split(split_config, bufnr)
  bufnr = bufnr or M.create_buffer()

  local position = split_config.position
  local cmd

  if position == "right" then
    cmd = "vsplit"
    vim.cmd(cmd)
    vim.cmd("wincmd l")
  elseif position == "left" then
    cmd = "vsplit"
    vim.cmd(cmd)
    vim.cmd("wincmd h")
  elseif position == "top" then
    cmd = "split"
    vim.cmd(cmd)
    vim.cmd("wincmd k")
  elseif position == "bottom" then
    cmd = "split"
    vim.cmd(cmd)
    vim.cmd("wincmd j")
  else
    error("Invalid split position: " .. tostring(position))
  end

  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)

  -- サイズ設定
  if position == "right" or position == "left" then
    if split_config.width then
      local width = calculate_size(split_config.width, vim.o.columns)
      vim.api.nvim_win_set_width(winid, width)
    end
  else
    if split_config.height then
      local height = calculate_size(split_config.height, vim.o.lines)
      vim.api.nvim_win_set_height(winid, height)
    end
  end

  return winid, bufnr
end

---3パネルレイアウトを作成（inline preview用）
---@param config table レイアウト設定
---@return table layout レイアウト情報
function M.create_triple_panel_layout(config)
  config = config or {}

  -- メインフローティングウィンドウ
  local main_width = calculate_size(config.width or 0.9, vim.o.columns)
  local main_height = calculate_size(config.height or 0.9, vim.o.lines)
  local main_row = math.floor((vim.o.lines - main_height) / 2)
  local main_col = math.floor((vim.o.columns - main_width) / 2)

  local main_buf = M.create_buffer({ buftype = "nofile", filetype = "vibing-preview" })
  local main_win = vim.api.nvim_open_win(main_buf, true, {
    relative = "editor",
    width = main_width,
    height = main_height,
    row = main_row,
    col = main_col,
    style = "minimal",
    border = config.border or "rounded",
    title = config.title and " " .. config.title .. " " or nil,
    title_pos = "center",
  })

  -- 3つのパネルに分割
  vim.api.nvim_set_current_win(main_win)

  -- 左パネル（ファイルリスト）
  vim.cmd("vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local left_buf = M.create_buffer({ buftype = "nofile", filetype = "vibing-files" })
  vim.api.nvim_win_set_buf(left_win, left_buf)
  local left_width = math.floor(main_width * 0.25)
  vim.api.nvim_win_set_width(left_win, left_width)

  -- 右側を2つに分割
  vim.cmd("wincmd l")
  vim.cmd("split")

  -- 上パネル（diff）
  vim.cmd("wincmd k")
  local top_win = vim.api.nvim_get_current_win()
  local top_buf = M.create_buffer({ buftype = "nofile", filetype = "diff" })
  vim.api.nvim_win_set_buf(top_win, top_buf)

  -- 下パネル（response）
  vim.cmd("wincmd j")
  local bottom_win = vim.api.nvim_get_current_win()
  local bottom_buf = M.create_buffer({ buftype = "nofile", filetype = "markdown" })
  vim.api.nvim_win_set_buf(bottom_win, bottom_buf)

  return {
    main = { win = main_win, buf = main_buf },
    files = { win = left_win, buf = left_buf },
    diff = { win = top_win, buf = top_buf },
    response = { win = bottom_win, buf = bottom_buf },
  }
end

---ウィンドウを閉じる
---@param winid number
---@param force boolean?
function M.close_window(winid, force)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, force ~= false)
  end
end

---バッファを削除
---@param bufnr number
---@param force boolean?
function M.delete_buffer(bufnr, force)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = force ~= false })
  end
end

---バッファオプションを一括設定
---@param bufnr number
---@param opts table<string, any>
function M.set_buffer_options(bufnr, opts)
  for key, value in pairs(opts) do
    vim.bo[bufnr][key] = value
  end
end

---ウィンドウオプションを一括設定
---@param winid number
---@param opts table<string, any>
function M.set_window_options(winid, opts)
  for key, value in pairs(opts) do
    vim.wo[winid][key] = value
  end
end

return M
