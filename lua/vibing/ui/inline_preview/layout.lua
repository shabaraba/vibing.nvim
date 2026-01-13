---@class Vibing.InlinePreview.Layout
---インラインプレビューのレイアウト作成モジュール
local M = {}

local diff_util = require("vibing.core.utils.diff")
local Factory = require("vibing.infrastructure.ui.factory")

---インライン用レイアウト（アコーディオン式：Files左、Diff/Response右縦並び）
---@param state Vibing.InlinePreview.State
function M.create_inline_layout(state)
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  -- アコーディオン式レイアウト：Files左、Diff/Response右縦並び
  local files_width = math.floor(total_width * 0.25)
  local right_width = total_width - files_width - 3
  local collapsed_height = 1

  -- active_panelに応じて高さを計算
  local diff_height, response_height
  if state.active_panel == "diff" then
    diff_height = total_height - collapsed_height - 2
    response_height = collapsed_height
  else
    diff_height = collapsed_height
    response_height = total_height - collapsed_height - 2
  end

  -- ファイルリストバッファ（左側）
  state.buf_files = Factory.create_buffer({
    bufhidden = "wipe",
    modifiable = false,
  })

  state.win_files = Factory.create_float({
    width = files_width,
    height = total_height,
    row = start_row,
    col = start_col,
    border = "rounded",
    title = "Files",
    enter = true,
  }, state.buf_files)

  -- Diffプレビューバッファ（右上）
  state.buf_diff = diff_util.create_diff_buffer({})
  local diff_title = state.active_panel == "diff" and "▼ Diff" or "▶ Diff"
  state.win_diff = Factory.create_float({
    width = right_width,
    height = diff_height,
    row = start_row,
    col = start_col + files_width + 3,
    border = "rounded",
    title = diff_title,
    enter = false,
  }, state.buf_diff)

  -- レスポンスバッファ（右下）
  state.buf_response = Factory.create_buffer({
    bufhidden = "wipe",
    modifiable = false,
    filetype = "markdown",
  })

  local response_title = state.active_panel == "response" and "▼ Response" or "▶ Response"
  state.win_response = Factory.create_float({
    width = right_width,
    height = response_height,
    row = start_row + diff_height + 2,
    col = start_col + files_width + 3,
    border = "rounded",
    title = response_title,
    enter = false,
  }, state.buf_response)
end

---チャット用レイアウト（2パネル：Files, Diff）
---@param state Vibing.InlinePreview.State
function M.create_chat_layout(state)
  local is_wide = vim.o.columns >= 120
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  if is_wide then
    -- 横並びレイアウト
    local files_width = math.floor(total_width * 0.3)
    local diff_width = total_width - files_width - 3

    state.buf_files = Factory.create_buffer({
      bufhidden = "wipe",
      modifiable = false,
    })

    state.win_files = Factory.create_float({
      width = files_width,
      height = total_height,
      row = start_row,
      col = start_col,
      border = "rounded",
      title = "Files",
      enter = true,
    }, state.buf_files)

    state.buf_diff = diff_util.create_diff_buffer({})
    state.win_diff = Factory.create_float({
      width = diff_width,
      height = total_height,
      row = start_row,
      col = start_col + files_width + 3,
      border = "rounded",
      title = "Diff Preview",
      enter = false,
    }, state.buf_diff)
  else
    -- 縦並びレイアウト
    local files_height = 8
    local diff_height = total_height - files_height - 2

    state.buf_files = Factory.create_buffer({
      bufhidden = "wipe",
      modifiable = false,
    })

    state.win_files = Factory.create_float({
      width = total_width,
      height = files_height,
      row = start_row,
      col = start_col,
      border = "rounded",
      title = "Files",
      enter = true,
    }, state.buf_files)

    state.buf_diff = diff_util.create_diff_buffer({})
    state.win_diff = Factory.create_float({
      width = total_width,
      height = diff_height,
      row = start_row + files_height + 2,
      col = start_col,
      border = "rounded",
      title = "Diff Preview",
      enter = false,
    }, state.buf_diff)
  end
end

---レイアウトを作成（モードに応じて選択）
---@param state Vibing.InlinePreview.State
function M.create(state)
  if state.mode == "inline" then
    M.create_inline_layout(state)
  else
    M.create_chat_layout(state)
  end
end

return M
