---@class Vibing.PatchViewer.Actions
---ビューアのキーが呼ぶ操作。`init.lua` は組み立てと後片付けだけを持つ。
local M = {}

local ui = require("vibing.ui.patch_viewer.ui")
local window = require("vibing.ui.patch_viewer.window")
local diff_mode = require("vibing.ui.patch_viewer.diff_mode")
local keymaps = require("vibing.ui.patch_viewer.keymaps")
local revert = require("vibing.ui.patch_viewer.revert")

---side-by-side と unified のどちらで開くか。**一度切り替えたらそのNeovimのあいだは覚える**。
---表示の好みなので、ファイルを開き直すたびに押し直させない
---@type "split"|"unified"|nil
local layout = nil

---@return "split"|"unified"
function M.initial_layout()
  if not layout then
    layout = (((require("vibing.config").options or {}).diff or {}).layout) or "split"
  end
  return layout
end

---一覧と差分を描き直し、Afterに出た実ファイルへビューア用のキーを張り直す。
---Afterのバッファは選択のたびに差し替わるので、この2つは必ず対で起きる
---@param state Vibing.PatchViewer.State
---@param callbacks table
function M.refresh(state, callbacks)
  ui.render_all(state)
  keymaps.setup_after(state, state.buf_after, callbacks)
end

---@param state Vibing.PatchViewer.State
---@param callbacks table
---@param direction number
function M.select_file(state, callbacks, direction)
  local new_idx = state.selected_idx + direction
  if new_idx < 1 then
    new_idx = #state.files
  elseif new_idx > #state.files then
    new_idx = 1
  end
  state.selected_idx = new_idx
  M.refresh(state, callbacks)

  -- 一覧のカーソルも一緒に動かす。動かさないと `<CR>` が「見えている選択」ではなく
  -- 置き去りのカーソル行を開く
  if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
    pcall(vim.api.nvim_win_set_cursor, state.win_files, { new_idx + 2, 0 })
  end
end

---@param state Vibing.PatchViewer.State
---@param callbacks table
function M.select_from_cursor(state, callbacks)
  if not state.win_files or not vim.api.nvim_win_is_valid(state.win_files) then
    return
  end
  local file_idx = vim.api.nvim_win_get_cursor(state.win_files)[1] - 2
  if file_idx >= 1 and file_idx <= #state.files then
    state.selected_idx = file_idx
    M.refresh(state, callbacks)
  end
end

---side-by-side と unified を入れ替える。ペインの数が変わるので、組み直してから描き直す
---@param state Vibing.PatchViewer.State
---@param callbacks table
function M.toggle_layout(state, callbacks)
  if not (state.win_after and vim.api.nvim_win_is_valid(state.win_after)) then
    return
  end

  layout = (M.initial_layout() == "unified") and "split" or "unified"
  state.layout = layout

  -- 実ファイルに張ったキーを先に外す。組み直しで `after_mapped` を見失うと `q` を奪ったままになる
  keymaps.clear_after(state)
  diff_mode.leave(state)
  window.create_layout(state)
  keymaps.setup(state, callbacks)
  M.refresh(state, callbacks)
end

---選択中のファイルを通常ウィンドウで開く。フロートは閉じる
---@param state Vibing.PatchViewer.State
---@param close fun()
function M.open_selected_file(state, close)
  local _, abs = ui._resolve_selected(state)
  abs = abs or state.files[state.selected_idx]
  if not abs then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end

  close()
  require("vibing.ui.code_window").open_file(abs)
end

---@param state Vibing.PatchViewer.State
---@param close fun()
function M.revert_selected(state, close)
  if not state.session_id or not state.patch_filename then
    vim.notify("No patch to revert", vim.log.levels.WARN)
    return
  end
  local selected_file = state.files[state.selected_idx]
  if not selected_file then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end
  if revert.revert_single_file(state.session_id, state.patch_filename, selected_file) then
    close()
  end
end

---@param state Vibing.PatchViewer.State
---@param close fun()
function M.revert_all(state, close)
  if not state.session_id or not state.patch_filename then
    vim.notify("No patch to revert", vim.log.levels.WARN)
    return
  end
  local choice = vim.fn.confirm(string.format("Revert all %d file(s) in this patch?", #state.files), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  if revert.revert_all_files(state.session_id, state.patch_filename) then
    close()
  end
end

return M
