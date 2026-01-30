---@class Vibing.PatchViewer.UI
local M = {}

local diff_util = require("vibing.core.utils.diff")
local parser = require("vibing.ui.patch_viewer.parser")

---@param state Vibing.PatchViewer.State
function M.render_all(state)
  M.render_files_panel(state)
  M.render_diff_panel(state)
end

---@param state Vibing.PatchViewer.State
function M.render_files_panel(state)
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local lines = { string.format("Files (%d):", #state.files), "" }

  for i, file in ipairs(state.files) do
    local marker = (i == state.selected_idx) and "▶ " or "  "
    table.insert(lines, marker .. file)
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 30))
  local help_start = #lines
  table.insert(lines, "j/k    Navigate files")
  table.insert(lines, "<CR>   Select file")
  table.insert(lines, "<Tab>  Switch pane")
  table.insert(lines, "r      Revert selected file")
  table.insert(lines, "R      Revert all files")
  table.insert(lines, "q      Quit")

  vim.bo[state.buf_files].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.bo[state.buf_files].modifiable = false

  local ns_id = vim.api.nvim_create_namespace("vibing_patch_viewer")
  vim.api.nvim_buf_clear_namespace(state.buf_files, ns_id, 0, -1)

  if state.selected_idx > 0 and state.selected_idx <= #state.files then
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Visual", state.selected_idx + 1, 0, -1)
  end

  for i = help_start, #lines - 1 do
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Comment", i, 0, -1)
  end
end

---@param state Vibing.PatchViewer.State
function M.render_diff_panel(state)
  if not state.buf_diff or not vim.api.nvim_buf_is_valid(state.buf_diff) then
    return
  end

  if #state.files == 0 then
    diff_util.update_diff_buffer(state.buf_diff, { "No files in patch" })
    return
  end

  local file = state.files[state.selected_idx]
  local file_diff = parser.extract_file_diff(state.patch_content, file)

  if not file_diff or file_diff == "" then
    diff_util.update_diff_buffer(state.buf_diff, { "No changes for " .. file })
    return
  end

  local diff_lines = vim.split(file_diff, "\n", { plain = true })
  diff_util.update_diff_buffer(state.buf_diff, diff_lines)
end

return M
