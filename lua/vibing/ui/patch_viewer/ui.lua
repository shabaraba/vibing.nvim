---@class Vibing.PatchViewer.UI
local M = {}

local parser = require("vibing.ui.patch_viewer.parser")
local window = require("vibing.ui.patch_viewer.window")
local diff_mode = require("vibing.ui.patch_viewer.diff_mode")
local files_panel = require("vibing.ui.patch_viewer.files_panel")
local unified = require("vibing.ui.patch_viewer.unified")
local PatchText = require("vibing.core.utils.patch_text")

---@param state Vibing.PatchViewer.State
function M.render_all(state)
  files_panel.render(state)
  M.render_diff_panes(state)
end

M.render_files_panel = files_panel.render

---選択中のファイルについて、patchが指す絶対パスと生のパスを解決する
---@param state Vibing.PatchViewer.State
---@return string? raw patch内表記
---@return string? abs 実ファイルの絶対パス
function M._resolve_selected(state)
  local display = state.files[state.selected_idx]
  if not display or not state.base_dir or not state.patch_content then
    return nil, nil
  end
  local raw = parser.raw_path(state.patch_content, display)
  if not raw then
    return nil, nil
  end
  return raw, state.base_dir .. "/" .. raw
end

---@param state Vibing.PatchViewer.State
function M.render_diff_panes(state)
  local display = state.files[state.selected_idx]
  if not display or not state.win_after or not vim.api.nvim_win_is_valid(state.win_after) then
    return
  end

  local file_diff = state.patch_content and parser.extract_file_diff(state.patch_content, display)
  local raw, abs = M._resolve_selected(state)
  window.set_after_title(state, display)

  local before
  if state.layout ~= "unified" and raw and file_diff then
    before = PatchText.before_lines(state.base_dir, raw, file_diff)
  end

  -- ターンで削除されたファイル、バイナリ、baseヘッダの無い旧patch。どれも「実ファイルと
  -- 並べる」が成立しないので、統一diffのテキストをそのまま出す。unified を選んでいる時も
  -- 同じ描き方になるが、そちらはBeforeペインが存在しないところが違う
  if not before or not abs or vim.fn.filereadable(abs) ~= 1 then
    M._render_unified(state, display, file_diff)
    return
  end

  M._render_side_by_side(state, before, abs)
end

---@param state Vibing.PatchViewer.State
---@param before string[]
---@param abs string
function M._render_side_by_side(state, before, abs)
  diff_mode.leave(state)
  -- 直前に unified を出していた時のために戻す。`win_after` は使い回されるので、
  -- 残すと実ファイルの上に統一diffの行番号が出たままになる
  unified.reset_window(state.win_after)

  local after_buf = vim.fn.bufadd(abs)
  vim.fn.bufload(after_buf)
  vim.api.nvim_win_set_buf(state.win_after, after_buf)
  state.buf_after = after_buf

  vim.bo[state.buf_before].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_before, 0, -1, false, before)
  vim.bo[state.buf_before].modifiable = false
  -- 構文ハイライトは実ファイル側の判定に合わせる。Beforeはスクラッチなので名前から決まらない
  vim.bo[state.buf_before].filetype = vim.bo[after_buf].filetype

  diff_mode.enter(state)

  -- 先頭の変更箇所へ。変更が無ければ `]c` は失敗するだけ
  vim.api.nvim_win_call(state.win_after, function()
    pcall(vim.cmd, "normal! gg]c")
  end)
end

---@param state Vibing.PatchViewer.State
---@param display string
---@param file_diff string?
function M._render_unified(state, display, file_diff)
  diff_mode.leave(state)

  if ((require("vibing.config").options or {}).diff or {}).highlights == false then
    state.buf_after = unified.render_plain(state.win_after, file_diff, display)
  else
    -- filetypeは拡張子だけで決まるので、ターンで削除されて実体が無いファイルでも当たる
    local _, abs = M._resolve_selected(state)
    state.buf_after = unified.render(state.win_after, abs or display, file_diff, display)
  end

  -- unified を選んでいる時はBeforeペインがそもそも無い。ここに来るのは side-by-side の
  -- つもりで開けなかった時だけなので、その理由を左に書く
  if not (state.buf_before and vim.api.nvim_buf_is_valid(state.buf_before)) then
    return
  end

  vim.bo[state.buf_before].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_before, 0, -1, false, {
    "(no side-by-side view for this entry)",
    "",
    "The file was deleted in this turn, is binary,",
    "or the patch predates the base header.",
  })
  vim.bo[state.buf_before].modifiable = false
  vim.bo[state.buf_before].filetype = ""
end

return M
