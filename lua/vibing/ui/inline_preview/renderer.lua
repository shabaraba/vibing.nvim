---@class Vibing.InlinePreview.Renderer
---インラインプレビューのレンダリングモジュール
local M = {}

local diff_util = require("vibing.core.utils.diff")

---ファイルリストパネルを描画
---@param state Vibing.InlinePreview.State
function M.render_files_panel(state)
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local lines = { string.format("Files (%d):", #state.modified_files), "" }

  if #state.modified_files == 0 then
    table.insert(lines, "No files modified")
  else
    for i, file in ipairs(state.modified_files) do
      local marker = (i == state.selected_file_idx) and "▶ " or "  "
      table.insert(lines, marker .. file)
    end
  end

  -- Add separator and help text
  table.insert(lines, "")
  table.insert(lines, string.rep("─", 40))
  local help_start_idx = #lines
  table.insert(lines, "<CR> Select")
  table.insert(lines, "<Tab> Next")
  table.insert(lines, "<S-Tab> Prev")
  table.insert(lines, "a Accept")
  table.insert(lines, "r Reject")
  table.insert(lines, "q Quit")

  vim.bo[state.buf_files].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.bo[state.buf_files].modifiable = false

  -- 選択行をハイライト
  local ns_id = vim.api.nvim_create_namespace("vibing_inline_preview")
  vim.api.nvim_buf_clear_namespace(state.buf_files, ns_id, 0, -1)
  if state.selected_file_idx > 0 and state.selected_file_idx <= #state.modified_files then
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Visual", state.selected_file_idx + 1, 0, -1)
  end

  -- Highlight help text
  for i = help_start_idx, #lines - 1 do
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Comment", i, 0, -1)
  end
end

---Diffパネルを描画
---@param state Vibing.InlinePreview.State
function M.render_diff_panel(state)
  if not state.buf_diff or not vim.api.nvim_buf_is_valid(state.buf_diff) then
    return
  end

  -- Inline modeで折りたたまれている場合
  if state.mode == "inline" and state.active_panel ~= "diff" then
    diff_util.update_diff_buffer(state.buf_diff, { "Press Tab to expand Diff panel" })
    return
  end

  if #state.modified_files == 0 then
    diff_util.update_diff_buffer(state.buf_diff, { "No files modified" })
    return
  end

  local file = state.modified_files[state.selected_file_idx]
  local diff_data = state.diffs[file]

  if not diff_data then
    diff_util.update_diff_buffer(state.buf_diff, { "Error: Diff not available for " .. file })
    return
  end

  if diff_data.error then
    diff_util.update_diff_buffer(state.buf_diff, diff_data.lines)
    return
  end

  diff_util.update_diff_buffer(state.buf_diff, diff_data.lines)
end

---レスポンスパネルを描画
---@param state Vibing.InlinePreview.State
function M.render_response_panel(state)
  if not state.buf_response or not vim.api.nvim_buf_is_valid(state.buf_response) then
    return
  end

  -- Inline modeで折りたたまれている場合
  if state.mode == "inline" and state.active_panel ~= "response" then
    vim.bo[state.buf_response].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf_response, 0, -1, false, { "Press Tab to expand Response panel" })
    vim.bo[state.buf_response].modifiable = false
    return
  end

  -- response_textを改行で分割
  local response_lines = vim.split(state.response_text, "\n", { plain = true })
  local lines = {}
  table.insert(lines, "Response:")
  for _, line in ipairs(response_lines) do
    table.insert(lines, line)
  end

  vim.bo[state.buf_response].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_response, 0, -1, false, lines)
  vim.bo[state.buf_response].modifiable = false
end

---全パネルを再描画
---@param state Vibing.InlinePreview.State
function M.render_all(state)
  M.render_files_panel(state)
  M.render_diff_panel(state)
  if state.mode == "inline" then
    M.render_response_panel(state)
  end
end

return M
