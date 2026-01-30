---@class Vibing.PatchViewer.Window
local M = {}

local diff_util = require("vibing.core.utils.diff")

---@param state Vibing.PatchViewer.State
function M.create_layout(state)
  M.close_windows(state)

  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.8)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  local files_width = math.floor(total_width * 0.3)
  local diff_width = total_width - files_width - 3

  local Factory = require("vibing.infrastructure.ui.factory")

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
end

---@param state Vibing.PatchViewer.State
function M.close_windows(state)
  for _, win in ipairs({ state.win_files, state.win_diff }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ state.buf_files, state.buf_diff }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state.win_files = nil
  state.win_diff = nil
  state.buf_files = nil
  state.buf_diff = nil
end

---@param state Vibing.PatchViewer.State
---@param direction number
function M.cycle_window(state, direction)
  local wins = { state.win_files, state.win_diff }
  local current_win = vim.api.nvim_get_current_win()

  local current_idx = nil
  for i, win in ipairs(wins) do
    if win == current_win then
      current_idx = i
      break
    end
  end

  if not current_idx then
    if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      vim.api.nvim_set_current_win(wins[1])
    end
    return
  end

  local next_idx = current_idx + direction
  if next_idx > #wins then
    next_idx = 1
  elseif next_idx < 1 then
    next_idx = #wins
  end

  if wins[next_idx] and vim.api.nvim_win_is_valid(wins[next_idx]) then
    vim.api.nvim_set_current_win(wins[next_idx])
  end
end

return M
