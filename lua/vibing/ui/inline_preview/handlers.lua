---@class Vibing.InlinePreview.Handlers
---インラインプレビューのイベントハンドラーモジュール
local M = {}

local Renderer = require("vibing.ui.inline_preview.renderer")

---カーソル位置からファイルを選択
---@param state Vibing.InlinePreview.State
function M.on_file_select_from_cursor(state)
  if not state.win_files or not vim.api.nvim_win_is_valid(state.win_files) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.win_files)
  local cursor_line = cursor[1]
  local file_idx = cursor_line - 2  -- ファイルリストは3行目から

  if file_idx < 1 or file_idx > #state.modified_files then
    return
  end

  state.selected_file_idx = file_idx
  Renderer.render_files_panel(state)
  Renderer.render_diff_panel(state)
end

---ファイル選択を変更
---@param state Vibing.InlinePreview.State
---@param direction number 1で次、-1で前
function M.on_file_select(state, direction)
  local new_idx = state.selected_file_idx + direction

  if new_idx < 1 then
    new_idx = #state.modified_files
  elseif new_idx > #state.modified_files then
    new_idx = 1
  end

  state.selected_file_idx = new_idx
  Renderer.render_files_panel(state)
  Renderer.render_diff_panel(state)
end

---Accept処理（変更を保持）
---@param state Vibing.InlinePreview.State
---@param close_callback function
function M.on_accept(state, close_callback)
  close_callback()
  if #state.modified_files == 0 then
    vim.notify("No files modified", vim.log.levels.INFO)
  else
    vim.notify(
      string.format("Accepted changes to %d files", #state.modified_files),
      vim.log.levels.INFO
    )
  end
end

---Reject処理（変更を元に戻す）
---@param state Vibing.InlinePreview.State
---@param close_callback function
function M.on_reject(state, close_callback)
  if #state.modified_files == 0 then
    close_callback()
    vim.notify("No files to reject", vim.log.levels.INFO)
    return
  end

  local BufferReload = require("vibing.core.utils.buffer_reload")
  local restored_count = 0

  for _, file in ipairs(state.modified_files) do
    local saved_lines = state.saved_contents[file]
    if saved_lines then
      local abs_path = vim.fn.fnamemodify(file, ":p")
      vim.fn.writefile(saved_lines, abs_path)
      BufferReload.reload_if_loaded(abs_path)
      restored_count = restored_count + 1
    end
  end

  close_callback()
  vim.notify(
    string.format("Rejected changes, restored %d files", restored_count),
    vim.log.levels.INFO
  )
end

---Quit処理
---@param close_callback function
function M.on_quit(close_callback)
  close_callback()
end

---プレビューUIウィンドウ間を循環移動
---@param state Vibing.InlinePreview.State
---@param direction number 1で次、-1で前
function M.cycle_window(state, direction)
  local current_win = vim.api.nvim_get_current_win()

  local wins = { state.win_files, state.win_diff }
  if state.mode == "inline" and state.win_response then
    table.insert(wins, state.win_response)
  end

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

---アコーディオンパネル切り替え（inline modeのみ）
---@param state Vibing.InlinePreview.State
---@param target_panel "diff"|"response"
function M.switch_panel(state, target_panel)
  if state.mode ~= "inline" then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local target_win = target_panel == "diff" and state.win_diff or state.win_response
  
  if state.active_panel == target_panel and current_win == target_win then
    return
  end

  state.active_panel = target_panel

  -- レイアウト再計算
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)
  local files_width = math.floor(total_width * 0.25)
  local collapsed_height = 1

  local diff_height, response_height
  if state.active_panel == "diff" then
    diff_height = total_height - collapsed_height - 2
    response_height = collapsed_height
  else
    diff_height = collapsed_height
    response_height = total_height - collapsed_height - 2
  end

  -- Diffウィンドウの更新
  if state.win_diff and vim.api.nvim_win_is_valid(state.win_diff) then
    local diff_title = state.active_panel == "diff" and "▼ Diff" or "▶ Diff"
    vim.api.nvim_win_set_config(state.win_diff, {
      relative = "editor",
      width = total_width - files_width - 3,
      height = diff_height,
      row = start_row,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = " " .. diff_title .. " ",
      title_pos = "center",
    })
  end

  -- Responseウィンドウの更新
  if state.win_response and vim.api.nvim_win_is_valid(state.win_response) then
    local response_title = state.active_panel == "response" and "▼ Response" or "▶ Response"
    vim.api.nvim_win_set_config(state.win_response, {
      relative = "editor",
      width = total_width - files_width - 3,
      height = response_height,
      row = start_row + diff_height + 2,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = " " .. response_title .. " ",
      title_pos = "center",
    })
  end

  -- 展開したパネルにフォーカス
  target_win = target_panel == "diff" and state.win_diff or state.win_response
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end

  Renderer.render_all(state)
end

return M
